package main

// 外部ライブラリを使わない QR コード生成（バイトモード・誤り訂正レベル M・型番 1〜10）。
// アルゴリズムは QR コード規格（JIS X 0510 / ISO/IEC 18004）に従う。

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/png"
)

// 誤り訂正レベル M の表（添字 = 型番）
var eccPerBlockM = [11]int{-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26}
var numBlocksM = [11]int{-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5}

type QR struct {
	Version int
	Size    int
	Modules [][]bool // [y][x] true = 黒
	isFunc  [][]bool
}

func rawDataModules(ver int) int {
	r := (16*ver+128)*ver + 64
	if ver >= 2 {
		na := ver/7 + 2
		r -= (25*na-10)*na - 55
		if ver >= 7 {
			r -= 36
		}
	}
	return r
}

func dataCodewords(ver int) int {
	return rawDataModules(ver)/8 - eccPerBlockM[ver]*numBlocksM[ver]
}

// EncodeQR は文字列を QR にする
func EncodeQR(text string) (*QR, error) {
	data := []byte(text)
	ver := 0
	for v := 1; v <= 10; v++ {
		ccBits := 8
		if v >= 10 {
			ccBits = 16
		}
		if 4+ccBits+len(data)*8 <= dataCodewords(v)*8 {
			ver = v
			break
		}
	}
	if ver == 0 {
		return nil, errors.New("QR に入りきりません")
	}
	// ビット列を作る
	var bits []bool
	appendBits := func(val uint32, n int) {
		for i := n - 1; i >= 0; i-- {
			bits = append(bits, (val>>uint(i))&1 == 1)
		}
	}
	appendBits(0x4, 4) // バイトモード
	if ver >= 10 {
		appendBits(uint32(len(data)), 16)
	} else {
		appendBits(uint32(len(data)), 8)
	}
	for _, b := range data {
		appendBits(uint32(b), 8)
	}
	capBits := dataCodewords(ver) * 8
	for i := 0; i < 4 && len(bits) < capBits; i++ { // 終端パターン
		bits = append(bits, false)
	}
	for len(bits)%8 != 0 {
		bits = append(bits, false)
	}
	for pad := uint32(0xEC); len(bits) < capBits; pad ^= 0xEC ^ 0x11 {
		appendBits(pad, 8)
	}
	cw := make([]byte, len(bits)/8)
	for i, b := range bits {
		if b {
			cw[i>>3] |= 1 << uint(7-(i&7))
		}
	}
	all := addECCAndInterleave(cw, ver)

	q := &QR{Version: ver, Size: ver*4 + 17}
	q.Modules = make([][]bool, q.Size)
	q.isFunc = make([][]bool, q.Size)
	for i := range q.Modules {
		q.Modules[i] = make([]bool, q.Size)
		q.isFunc[i] = make([]bool, q.Size)
	}
	q.drawFunctionPatterns()
	q.drawCodewords(all)

	// 8種類のマスクから減点の最も少ないものを選ぶ
	best, bestPenalty := 0, 1<<30
	for m := 0; m < 8; m++ {
		q.applyMask(m)
		q.drawFormatBits(m)
		if p := q.penalty(); p < bestPenalty {
			best, bestPenalty = m, p
		}
		q.applyMask(m) // 元に戻す（XOR）
	}
	q.applyMask(best)
	q.drawFormatBits(best)
	return q, nil
}

func (q *QR) set(x, y int, dark bool) {
	q.Modules[y][x] = dark
	q.isFunc[y][x] = true
}

func (q *QR) drawFunctionPatterns() {
	n := q.Size
	for i := 0; i < n; i++ { // タイミングパターン
		q.set(6, i, i%2 == 0)
		q.set(i, 6, i%2 == 0)
	}
	for _, c := range [][2]int{{3, 3}, {n - 4, 3}, {3, n - 4}} { // 位置検出パターン
		for dy := -4; dy <= 4; dy++ {
			for dx := -4; dx <= 4; dx++ {
				x, y := c[0]+dx, c[1]+dy
				if x < 0 || x >= n || y < 0 || y >= n {
					continue
				}
				d := max(abs(dx), abs(dy))
				q.set(x, y, d != 2 && d != 4)
			}
		}
	}
	pos := alignmentPositions(q.Version)
	na := len(pos)
	for i := 0; i < na; i++ { // 位置合わせパターン
		for j := 0; j < na; j++ {
			if (i == 0 && j == 0) || (i == 0 && j == na-1) || (i == na-1 && j == 0) {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					q.set(pos[i]+dx, pos[j]+dy, max(abs(dx), abs(dy)) != 1)
				}
			}
		}
	}
	q.drawFormatBits(0) // 場所を確保（後で上書き）
	if q.Version >= 7 {
		rem := q.Version
		for i := 0; i < 12; i++ {
			rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
		}
		bits := q.Version<<12 | rem
		for i := 0; i < 18; i++ {
			b := (bits>>uint(i))&1 == 1
			a, c := n-11+i%3, i/3
			q.set(a, c, b)
			q.set(c, a, b)
		}
	}
}

func alignmentPositions(ver int) []int {
	if ver == 1 {
		return nil
	}
	na := ver/7 + 2
	step := (ver*4 + na*2 + 1) / (na*2 - 2) * 2
	res := make([]int, na)
	res[0] = 6
	p := ver*4 + 17 - 7
	for i := na - 1; i >= 1; i-- {
		res[i] = p
		p -= step
	}
	return res
}

func (q *QR) drawFormatBits(mask int) {
	data := 0<<3 | mask // レベル M のフォーマット値は 0
	rem := data
	for i := 0; i < 10; i++ {
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	}
	bits := (data<<10 | rem) ^ 0x5412
	bit := func(i int) bool { return (bits>>uint(i))&1 == 1 }
	n := q.Size
	for i := 0; i <= 5; i++ {
		q.set(8, i, bit(i))
	}
	q.set(8, 7, bit(6))
	q.set(8, 8, bit(7))
	q.set(7, 8, bit(8))
	for i := 9; i < 15; i++ {
		q.set(14-i, 8, bit(i))
	}
	for i := 0; i < 8; i++ {
		q.set(n-1-i, 8, bit(i))
	}
	for i := 8; i < 15; i++ {
		q.set(8, n-15+i, bit(i))
	}
	q.set(8, n-8, true) // 常に黒のモジュール
}

func (q *QR) drawCodewords(data []byte) {
	n := q.Size
	i := 0
	for right := n - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		for vert := 0; vert < n; vert++ {
			for j := 0; j < 2; j++ {
				x := right - j
				upward := (right+1)&2 == 0
				y := vert
				if upward {
					y = n - 1 - vert
				}
				if !q.isFunc[y][x] && i < len(data)*8 {
					q.Modules[y][x] = (data[i>>3]>>uint(7-(i&7)))&1 == 1
					i++
				}
			}
		}
	}
}

func (q *QR) applyMask(m int) {
	for y := 0; y < q.Size; y++ {
		for x := 0; x < q.Size; x++ {
			var inv bool
			switch m {
			case 0:
				inv = (x+y)%2 == 0
			case 1:
				inv = y%2 == 0
			case 2:
				inv = x%3 == 0
			case 3:
				inv = (x+y)%3 == 0
			case 4:
				inv = (x/3+y/2)%2 == 0
			case 5:
				inv = x*y%2+x*y%3 == 0
			case 6:
				inv = (x*y%2+x*y%3)%2 == 0
			default:
				inv = ((x+y)%2+x*y%3)%2 == 0
			}
			if inv && !q.isFunc[y][x] {
				q.Modules[y][x] = !q.Modules[y][x]
			}
		}
	}
}

// penalty は読み取りやすさの減点（同色の連続・2×2 ブロック・白黒の偏り）
func (q *QR) penalty() int {
	n := q.Size
	p := 0
	for y := 0; y < n; y++ {
		run := 1
		for x := 1; x < n; x++ {
			if q.Modules[y][x] == q.Modules[y][x-1] {
				run++
				if run == 5 {
					p += 3
				} else if run > 5 {
					p++
				}
			} else {
				run = 1
			}
		}
	}
	for x := 0; x < n; x++ {
		run := 1
		for y := 1; y < n; y++ {
			if q.Modules[y][x] == q.Modules[y-1][x] {
				run++
				if run == 5 {
					p += 3
				} else if run > 5 {
					p++
				}
			} else {
				run = 1
			}
		}
	}
	dark := 0
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			if q.Modules[y][x] {
				dark++
			}
			if x+1 < n && y+1 < n {
				c := q.Modules[y][x]
				if q.Modules[y][x+1] == c && q.Modules[y+1][x] == c && q.Modules[y+1][x+1] == c {
					p += 3
				}
			}
		}
	}
	// 位置検出パターンに似た並び（1:1:3:1:1 の前後に白4つ）は誤検出の元なので大きく減点
	pat1 := []bool{true, false, true, true, true, false, true, false, false, false, false}
	pat2 := []bool{false, false, false, false, true, false, true, true, true, false, true}
	at := func(x, y int) bool {
		if x < 0 || y < 0 || x >= n || y >= n {
			return false
		}
		return q.Modules[y][x]
	}
	for a := 0; a < n; a++ {
		for b := -4; b < n; b++ {
			for _, pat := range [][]bool{pat1, pat2} {
				h, v := true, true
				for k, want := range pat {
					if at(b+k, a) != want {
						h = false
					}
					if at(a, b+k) != want {
						v = false
					}
				}
				if h {
					p += 40
				}
				if v {
					p += 40
				}
			}
		}
	}
	total := n * n
	k := abs(dark*20-total*10)/total - 1
	if k > 0 {
		p += k * 10
	}
	return p
}

func addECCAndInterleave(data []byte, ver int) []byte {
	nb := numBlocksM[ver]
	eccLen := eccPerBlockM[ver]
	raw := rawDataModules(ver) / 8
	numShort := nb - raw%nb
	shortLen := raw / nb
	div := rsDivisor(eccLen)
	blocks := make([][]byte, nb)
	k := 0
	for i := 0; i < nb; i++ {
		l := shortLen - eccLen
		if i >= numShort {
			l++
		}
		dat := append([]byte{}, data[k:k+l]...)
		k += l
		ecc := rsRemainder(dat, div)
		if i < numShort {
			dat = append(dat, 0)
		}
		blocks[i] = append(dat, ecc...)
	}
	var out []byte
	for i := 0; i < len(blocks[0]); i++ {
		for j := 0; j < nb; j++ {
			if i != shortLen-eccLen || j >= numShort {
				out = append(out, blocks[j][i])
			}
		}
	}
	return out
}

func gfMul(x, y byte) byte {
	var z int
	for i := 7; i >= 0; i-- {
		z = (z << 1) ^ ((z >> 7) * 0x11D)
		z ^= int((y>>uint(i))&1) * int(x)
	}
	return byte(z)
}

func rsDivisor(degree int) []byte {
	res := make([]byte, degree)
	res[degree-1] = 1
	root := byte(1)
	for i := 0; i < degree; i++ {
		for j := 0; j < degree; j++ {
			res[j] = gfMul(res[j], root)
			if j+1 < degree {
				res[j] ^= res[j+1]
			}
		}
		root = gfMul(root, 0x02)
	}
	return res
}

func rsRemainder(data, div []byte) []byte {
	res := make([]byte, len(div))
	for _, b := range data {
		f := b ^ res[0]
		copy(res, res[1:])
		res[len(res)-1] = 0
		for i := range res {
			res[i] ^= gfMul(div[i], f)
		}
	}
	return res
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// QRPNG は QR を PNG 画像にする（周囲に 4 モジュールの余白）
func QRPNG(text string, scale int) ([]byte, error) {
	q, err := EncodeQR(text)
	if err != nil {
		return nil, err
	}
	border := 4
	sz := (q.Size + border*2) * scale
	img := image.NewGray(image.Rect(0, 0, sz, sz))
	for y := 0; y < sz; y++ {
		for x := 0; x < sz; x++ {
			mx, my := x/scale-border, y/scale-border
			c := color.Gray{255}
			if mx >= 0 && my >= 0 && mx < q.Size && my < q.Size && q.Modules[my][mx] {
				c = color.Gray{0}
			}
			img.SetGray(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

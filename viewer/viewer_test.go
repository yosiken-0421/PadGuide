package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func newTestServer() (*Server, *Auth, *Hub, *fakeClock) {
	clk := &fakeClock{time.Unix(1_700_000_000, 0)}
	a := NewAuth(clk.now)
	h := NewHub()
	s := NewServer(a, h, "192.168.1.10", 48123, log.New(io.Discard, "", 0))
	return s, a, h, clk
}

// do は remote（接続元）と host を指定してリクエストを送る
func do(t *testing.T, s *Server, method, path, remote, host string, body string, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = remote
	if host != "" {
		req.Host = host
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	return rr
}

func pair(t *testing.T, s *Server, a *Auth) string {
	t.Helper()
	p := a.Pairing()
	rr := do(t, s, "POST", "/api/pair", "192.168.1.20:5000", "", `{"token":"`+p.Token+`","device":"iPhone"}`, "")
	if rr.Code != 200 {
		t.Fatalf("pair failed: %d %s", rr.Code, rr.Body.String())
	}
	var res struct{ Session string }
	_ = json.Unmarshal(rr.Body.Bytes(), &res)
	if len(res.Session) != 64 {
		t.Fatalf("セッショントークンの長さが不正: %d", len(res.Session))
	}
	return res.Session
}

func sampleResult() string {
	cells := make([]string, 30)
	conf := make([]string, 30)
	for i := range cells {
		cells[i] = `"fire"`
		conf[i] = "0.9"
	}
	return `{"type":"result","v":1,"ts":1,"cols":6,"rows":5,"cells":[` + strings.Join(cells, ",") +
		`],"confidence":[` + strings.Join(conf, ",") + `],"status":"ok","start":0,"end":1,"moves":["R"],"path":[0,1],` +
		`"arrows":[[0.5,0.5,1.5,0.5]],"combos":1,"cleared":3,"steps":1,"elapsedMs":10,"achieved":[],"source":"iphone"}`
}

// ---- 接続トークン ----

func TestPairingTokenIsOneTime(t *testing.T) {
	s, a, _, _ := newTestServer()
	old := a.Pairing().Token
	pair(t, s, a)
	rr := do(t, s, "POST", "/api/pair", "192.168.1.20:5000", "", `{"token":"`+old+`","device":"x"}`, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("使用済みトークンで接続できてしまった: %d", rr.Code)
	}
}

func TestPairingExpires(t *testing.T) {
	s, a, _, clk := newTestServer()
	tok := a.Pairing().Token
	clk.t = clk.t.Add(pairTTL + time.Second)
	rr := do(t, s, "POST", "/api/pair", "192.168.1.20:5000", "", `{"token":"`+tok+`","device":"x"}`, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("期限切れトークンで接続できてしまった: %d", rr.Code)
	}
	if a.Pairing().Token == tok {
		t.Fatal("期限切れ後に作り直されていない")
	}
}

func TestCodePairingAndLockout(t *testing.T) {
	s, a, _, _ := newTestServer()
	code := a.Pairing().Code
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	for i := 0; i < maxCodeAttempts; i++ {
		rr := do(t, s, "POST", "/api/pair", "192.168.1.20:5000", "", `{"code":"`+wrong+`","device":"x"}`, "")
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("間違ったコードが通った")
		}
	}
	if a.Pairing().Code == code {
		t.Fatal("入力ミスが続いたのにコードが作り直されていない")
	}
	rr := do(t, s, "POST", "/api/pair", "192.168.1.20:5000", "", `{"code":"`+code+`","device":"x"}`, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatal("作り直し前のコードで接続できてしまった")
	}
	ok := do(t, s, "POST", "/api/pair", "192.168.1.20:5000", "", `{"code":"`+a.Pairing().Code+`","device":"x"}`, "")
	if ok.Code != 200 {
		t.Fatalf("正しいコードで接続できない: %d", ok.Code)
	}
}

func TestSessionReissuedOnReconnect(t *testing.T) {
	s, a, _, _ := newTestServer()
	s1 := pair(t, s, a)
	s2 := pair(t, s, a)
	if s1 == s2 {
		t.Fatal("再接続でトークンが再発行されていない")
	}
	if a.Check(s1) {
		t.Fatal("古いトークンが有効なまま")
	}
	if !a.Check(s2) {
		t.Fatal("新しいトークンが無効")
	}
}

func TestSessionExpires(t *testing.T) {
	s, a, _, clk := newTestServer()
	tok := pair(t, s, a)
	clk.t = clk.t.Add(sessionTTL + time.Minute)
	if a.Check(tok) {
		t.Fatal("期限切れのセッションが有効")
	}
}

// ---- 不正接続の拒否 ----

func TestRejectsWithoutOrWithWrongToken(t *testing.T) {
	s, a, _, _ := newTestServer()
	pair(t, s, a)
	if rr := do(t, s, "POST", "/api/push", "192.168.1.20:5000", "", sampleResult(), ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("トークンなしで送信できた: %d", rr.Code)
	}
	bad := strings.Repeat("0", 64)
	if rr := do(t, s, "POST", "/api/push", "192.168.1.20:5000", "", sampleResult(), bad); rr.Code != http.StatusUnauthorized {
		t.Fatalf("偽トークンで送信できた: %d", rr.Code)
	}
}

func TestRejectsOutsideLAN(t *testing.T) {
	s, a, _, _ := newTestServer()
	tok := pair(t, s, a)
	if rr := do(t, s, "POST", "/api/push", "203.0.113.5:5000", "", sampleResult(), tok); rr.Code != http.StatusForbidden {
		t.Fatalf("LAN 外から送信できた: %d", rr.Code)
	}
	p := a.Pairing()
	if rr := do(t, s, "POST", "/api/pair", "8.8.8.8:5000", "", `{"token":"`+p.Token+`","device":"x"}`, ""); rr.Code != http.StatusForbidden {
		t.Fatalf("LAN 外から接続できた: %d", rr.Code)
	}
}

func TestViewerPagesAreLocalOnly(t *testing.T) {
	s, _, _, _ := newTestServer()
	if rr := do(t, s, "GET", "/qr.png", "192.168.1.20:5000", "192.168.1.10:48123", "", ""); rr.Code != http.StatusForbidden {
		t.Fatalf("別の端末から QR を見られた: %d", rr.Code)
	}
	if rr := do(t, s, "GET", "/qr.png", "127.0.0.1:5000", "evil.example:48123", "", ""); rr.Code != http.StatusForbidden {
		t.Fatalf("DNS リバインディング対策が効いていない: %d", rr.Code)
	}
	if rr := do(t, s, "GET", "/qr.png", "127.0.0.1:5000", "127.0.0.1:48123", "", ""); rr.Code != 200 {
		t.Fatalf("PC 自身から QR が見られない: %d", rr.Code)
	}
	if rr := do(t, s, "GET", "/", "127.0.0.1:5000", "localhost:48123", "", ""); rr.Code != 200 {
		t.Fatalf("PC 自身から画面が開けない: %d", rr.Code)
	}
}

func TestRejectsUnknownFields(t *testing.T) {
	s, a, _, _ := newTestServer()
	tok := pair(t, s, a)
	withImage := strings.Replace(sampleResult(), `"source":"iphone"`, `"source":"iphone","image":"AAAA"`, 1)
	if rr := do(t, s, "POST", "/api/push", "192.168.1.20:5000", "", withImage, tok); rr.Code != http.StatusBadRequest {
		t.Fatalf("画像付きのデータを受け付けた: %d", rr.Code)
	}
	if rr := do(t, s, "POST", "/api/push", "192.168.1.20:5000", "", sampleResult(), tok); rr.Code != http.StatusNoContent {
		t.Fatalf("正しいデータが受け付けられない: %d %s", rr.Code, rr.Body.String())
	}
}

func TestRejectsInvalidResult(t *testing.T) {
	bad := []string{
		strings.Replace(sampleResult(), `"cols":6`, `"cols":8`, 1),
		strings.Replace(sampleResult(), `"path":[0,1]`, `"path":[0,99]`, 1),
		strings.Replace(sampleResult(), `"moves":["R"]`, `"moves":["X"]`, 1),
		strings.Replace(sampleResult(), `"fire"`, `"rainbow"`, 1),
	}
	for _, b := range bad {
		if _, err := ParseResult([]byte(b)); err == nil {
			t.Fatalf("不正なデータを受け付けた: %s", b[:60])
		}
	}
}

// ---- 画面共有終了時の破棄 ----

func TestShareEndDiscardsData(t *testing.T) {
	s, a, h, _ := newTestServer()
	tok := pair(t, s, a)
	do(t, s, "POST", "/api/share", "192.168.1.20:5000", "", `{"type":"share","state":"started","ts":1}`, tok)
	do(t, s, "POST", "/api/push", "192.168.1.20:5000", "", sampleResult(), tok)
	if m, sharing := h.Snapshot(); m == nil || !sharing {
		t.Fatal("結果が保持されていない")
	}
	rr := do(t, s, "POST", "/api/share", "192.168.1.20:5000", "", `{"type":"share","state":"ended","ts":2}`, tok)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("終了通知が受け付けられない: %d", rr.Code)
	}
	if m, sharing := h.Snapshot(); m != nil || sharing {
		t.Fatal("画面共有終了後もデータが残っている")
	}
}

func TestDisconnectButtonDiscardsAndRevokes(t *testing.T) {
	s, a, h, _ := newTestServer()
	tok := pair(t, s, a)
	do(t, s, "POST", "/api/push", "192.168.1.20:5000", "", sampleResult(), tok)
	rr := do(t, s, "POST", "/api/disconnect", "127.0.0.1:5000", "127.0.0.1:48123", "", "")
	if rr.Code != http.StatusNoContent {
		t.Fatalf("切断できない: %d", rr.Code)
	}
	if a.Check(tok) {
		t.Fatal("切断後もトークンが有効")
	}
	if m, _ := h.Snapshot(); m != nil {
		t.Fatal("切断後もデータが残っている")
	}
}

// ---- mDNS ----

func TestMDNSAnswersServiceQuery(t *testing.T) {
	m := NewMDNS(net.IPv4(192, 168, 1, 10), 48123)
	// "_puzzleroute._tcp.local." の PTR を問い合わせ
	q := []byte{0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	q = append(q, encodeName(mdnsServiceType)...)
	q = append(q, 0, typePTR, 0, classIN)
	_, qs, err := parseQuestions(q)
	if err != nil || len(qs) != 1 || !strings.EqualFold(qs[0].Name, mdnsServiceType) {
		t.Fatalf("質問の読み取りに失敗: %v %v", err, qs)
	}
	ans, extra := m.Answer(qs)
	if len(ans) != 1 || ans[0].Type != typePTR || len(extra) != 3 {
		t.Fatalf("応答が不正: %d %d", len(ans), len(extra))
	}
	msg := buildMessage(0, ans, extra)
	// 応答の最初の名前が読めること
	name, _, err := readName(msg, 12)
	if err != nil || name != mdnsServiceType {
		t.Fatalf("応答の名前: %q %v", name, err)
	}
	if !bytes.Contains(msg, []byte{192, 168, 1, 10}) {
		t.Fatal("A レコードがない")
	}
	if a, _ := m.Answer([]dnsQuestion{{"_other._tcp.local.", typePTR, false}}); a != nil {
		t.Fatal("関係ない問い合わせに応答した")
	}
}

func TestReadNameWithCompression(t *testing.T) {
	msg := []byte{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	msg = append(msg, encodeName("local.")...)    // offset 12
	msg = append(msg, 3, 'a', 'b', 'c', 0xC0, 12) // abc + ポインタ
	n, next, err := readName(msg, 12+len(encodeName("local.")))
	if err != nil || n != "abc.local." || next != len(msg) {
		t.Fatalf("%q %d %v", n, next, err)
	}
}

// ---- QR ----

func TestQRStructure(t *testing.T) {
	text := "puzzleroute://pair?h=192.168.1.23&p=48123&t=0123456789abcdef0123456789abcdef"
	q, err := EncodeQR(text)
	if err != nil {
		t.Fatal(err)
	}
	if q.Size != q.Version*4+17 || q.Version != 5 {
		t.Fatalf("型番 %d サイズ %d", q.Version, q.Size)
	}
	// 3 隅の位置検出パターン（中心 3×3 が黒、その外周が白）
	for _, c := range [][2]int{{3, 3}, {q.Size - 4, 3}, {3, q.Size - 4}} {
		if !q.Modules[c[1]][c[0]] || q.Modules[c[1]-2][c[0]] {
			t.Fatal("位置検出パターンが不正")
		}
	}
	png, err := QRPNG(text, 4)
	if err != nil || !bytes.HasPrefix(png, []byte("\x89PNG")) {
		t.Fatal("PNG が作れない")
	}
	if _, err := EncodeQR(strings.Repeat("a", 400)); err == nil {
		t.Fatal("長すぎる文字列でエラーにならない")
	}
}

func TestReedSolomonKnownVector(t *testing.T) {
	// 規格書の例（型番1-M "01234567" のデータ符号語）に対する誤り訂正符号語
	data := []byte{0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11}
	want := []byte{0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55}
	got := rsRemainder(data, rsDivisor(10))
	if !bytes.Equal(got, want) {
		t.Fatalf("誤り訂正符号が規格の例と違う: % X", got)
	}
}

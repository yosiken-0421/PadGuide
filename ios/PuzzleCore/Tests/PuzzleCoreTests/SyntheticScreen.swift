import Foundation
@testable import PuzzleCore

/// テスト用の合成画面。第三者のゲーム画像は使わず、独自の円形カラーパネルを描く。
struct SyntheticScreen: PixelSource {
    let width: Int
    let height: Int
    private(set) var buf: [UInt8]

    /// 独自デザインの各ドロップ色
    static let palette: [OrbKind: RGB] = [
        .fire: RGB(230, 70, 55), .water: RGB(50, 140, 240), .wood: RGB(60, 190, 90),
        .light: RGB(245, 210, 70), .dark: RGB(150, 70, 205), .heart: RGB(250, 130, 195),
        .jammer: RGB(185, 190, 200), .poison: RGB(160, 120, 185), .mortalPoison: RGB(75, 35, 95),
    ]

    init(width: Int = 1179, height: Int = 2556, background: RGB = RGB(28, 22, 34)) {
        self.width = width
        self.height = height
        buf = [UInt8](repeating: 0, count: width * height * 3)
        fillRect(x: 0, y: 0, w: width, h: height, background)
    }

    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 3
        return (buf[i], buf[i + 1], buf[i + 2])
    }

    mutating func fillRect(x: Int, y: Int, w: Int, h: Int, _ c: RGB) {
        for yy in max(0, y)..<min(height, y + h) {
            for xx in max(0, x)..<min(width, x + w) {
                let i = (yy * width + xx) * 3
                buf[i] = c.r; buf[i + 1] = c.g; buf[i + 2] = c.b
            }
        }
    }

    mutating func fillCircle(cx: Double, cy: Double, r: Double, _ c: RGB) {
        let x0 = Int(cx - r), x1 = Int(cx + r), y0 = Int(cy - r), y1 = Int(cy + r)
        for yy in max(0, y0)...min(height - 1, y1) {
            for xx in max(0, x0)...min(width - 1, x1) {
                let dx = Double(xx) + 0.5 - cx, dy = Double(yy) + 0.5 - cy
                if dx * dx + dy * dy <= r * r {
                    let i = (yy * width + xx) * 3
                    buf[i] = c.r; buf[i + 1] = c.g; buf[i + 2] = c.b
                }
            }
        }
    }

    mutating func darken(by f: UInt8) {
        for i in 0..<buf.count { buf[i] /= f }
    }

    /// 盤面を描く。enhanced = true なら各ドロップの右下に白い「＋」模様を付ける
    mutating func drawBoard(_ board: Board, x: Double, y: Double, cell: Double, enhanced: Bool = false) {
        let s = board.size
        for r in 0..<s.rows {
            for c in 0..<s.cols {
                let checker = (r + c) % 2 == 0 ? RGB(58, 44, 40) : RGB(72, 54, 46)
                fillRect(x: Int(x + Double(c) * cell), y: Int(y + Double(r) * cell),
                         w: Int(cell) + 1, h: Int(cell) + 1, checker)
                let k = board[r, c]
                guard let col = Self.palette[k] else { continue }
                let cx = x + (Double(c) + 0.5) * cell, cy = y + (Double(r) + 0.5) * cell
                fillCircle(cx: cx, cy: cy, r: cell * 0.43, col)
                if enhanced {
                    // 強化マーク風の模様（独自）
                    let mx = Int(cx + cell * 0.22), my = Int(cy + cell * 0.22), t = Int(cell * 0.04)
                    fillRect(x: mx - t * 3, y: my - t / 2, w: t * 6, h: t, RGB(255, 255, 255))
                    fillRect(x: mx - t / 2, y: my - t * 3, w: t, h: t * 6, RGB(255, 255, 255))
                }
            }
        }
    }

    /// 盤面の上に、色の付いた四角形（キャラクター枠のような領域）を描く。誤検出しないことの確認用。
    mutating func drawDecoyRow(y: Int, size: Int) {
        let colors = [RGB(220, 60, 60), RGB(60, 120, 230), RGB(70, 200, 90), RGB(240, 220, 80), RGB(160, 70, 210), RGB(240, 140, 200)]
        for i in 0..<6 {
            fillRect(x: 10 + i * (width / 6), y: y, w: size, h: size, colors[i % colors.count])
        }
    }

    /// ランダムな盤面（乱数の種を固定）
    static func randomBoard(_ size: BoardSize, seed: UInt64, kinds: [OrbKind] = [.fire, .water, .wood, .light, .dark, .heart]) -> Board {
        var s = seed
        var cells: [OrbKind] = []
        for _ in 0..<size.count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            cells.append(kinds[Int((s >> 33) % UInt64(kinds.count))])
        }
        return Board(size: size, cells: cells)
    }
}

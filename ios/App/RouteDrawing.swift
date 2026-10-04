import UIKit
import PuzzleCore

/// 盤面とルートの描画（小窓とアプリ内の盤面で共通）。
///
/// 操作の順番を分かりやすくするため：
/// - これから動かす1手を一番太く白で強調し、その先の3手を色付きで、残りは細く薄く描く
/// - 動かし終わった手は灰色で目立たなくする（画面から進み具合が分かったとき）
/// - 開始位置は「START」、今の指の位置は「いま」、最後は「終」で示す
/// - 次の数手を光る点がなぞって動く（アニメーション）
enum RouteDrawing {

    static func orbColor(_ k: OrbKind) -> UIColor { UIColor(OrbStyle.color(k)) }

    /// 手順 i の色（最初は赤 → 最後は紫へ）
    static func stepColor(_ i: Int, of n: Int) -> UIColor {
        let frac = n > 1 ? CGFloat(i) / CGFloat(n - 1) : 0
        return UIColor(hue: ((350 - 92 * frac) / 360).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 1, alpha: 1)
    }

    /// これから動かす手の番号（0 始まり）
    static func nextStep(progress: Int?, steps: Int) -> Int { min(max(progress ?? 0, 0), steps) }

    /// 盤面を描く
    static func drawBoard(_ g: CGContext, board: Board, origin: CGPoint, cell: CGFloat, drawOrbs: Bool) {
        let cols = board.size.cols
        for i in 0..<board.size.count {
            let x = origin.x + CGFloat(i % cols) * cell
            let y = origin.y + CGFloat(i / cols) * cell
            let even = (i / cols + i % cols) % 2 == 0
            (even ? UIColor(red: 0.16, green: 0.20, blue: 0.31, alpha: 1) : UIColor(red: 0.19, green: 0.24, blue: 0.35, alpha: 1)).setFill()
            g.fill(CGRect(x: x, y: y, width: cell, height: cell))
            guard drawOrbs else { continue }
            orbColor(board.cells[i]).setFill()
            g.fillEllipse(in: CGRect(x: x + cell * 0.1, y: y + cell * 0.1, width: cell * 0.8, height: cell * 0.8))
            let mark = OrbStyle.mark(board.cells[i]) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: cell * 0.26, weight: .heavy),
                                                        .foregroundColor: UIColor.white.withAlphaComponent(0.85)]
            let sz = mark.size(withAttributes: attrs)
            mark.draw(at: CGPoint(x: x + (cell - sz.width) / 2, y: y + (cell - sz.height) / 2), withAttributes: attrs)
        }
    }

    /// ルートを描く。phase（0〜1）を渡すと、次の数手を光る点がなぞる
    static func drawRoute(_ g: CGContext, result r: ResultMessage, origin: CGPoint, cell: CGFloat,
                          progress: Int?, phase: CGFloat?) {
        guard r.status == "ok", let start = r.start, !r.arrows.isEmpty else { return }
        let n = r.arrows.count
        let cols = r.cols
        let next = nextStep(progress: progress, steps: n)
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell) }
        func seg(_ i: Int) -> (CGPoint, CGPoint) { let a = r.arrows[i]; return (pt(a[0], a[1]), pt(a[2], a[3])) }

        g.setLineCap(.round)
        g.setLineJoin(.round)

        // 描く順：遠い先 → 近い先 → 次の1手（重なったときに次の手が上に来るように）
        enum Kind { case done, far, near, current }
        func kind(_ i: Int) -> Kind {
            if progress != nil && i < next { return .done }
            if i == next { return .current }
            if i <= next + 3 { return .near }
            return .far
        }
        let order = (0..<n).sorted { a, b in
            let rank: (Kind) -> Int = { k in k == .done ? 0 : k == .far ? 1 : k == .near ? 2 : 3 }
            let ra = rank(kind(a)), rb = rank(kind(b))
            return ra != rb ? ra < rb : a > b
        }
        for i in order {
            let (p1, p2) = seg(i)
            switch kind(i) {
            case .done:
                stroke(g, p1, p2, width: cell * 0.05, color: UIColor.white.withAlphaComponent(0.18), outline: nil)
            case .far:
                stroke(g, p1, p2, width: cell * 0.06, color: stepColor(i, of: n).withAlphaComponent(0.45), outline: nil)
            case .near:
                stroke(g, p1, p2, width: cell * 0.12, color: stepColor(i, of: n), outline: UIColor.black.withAlphaComponent(0.7))
                arrowHead(g, p1, p2, size: cell * 0.22, color: stepColor(i, of: n))
            case .current:
                stroke(g, p1, p2, width: cell * 0.2, color: .white, outline: UIColor.black.withAlphaComponent(0.85))
                arrowHead(g, p1, p2, size: cell * 0.34, color: .white)
            }
        }

        // 手順番号（終わった手には付けない。重ならない位置を探す）
        var placed: [CGPoint] = []
        for i in 0..<n where kind(i) != .done {
            let k = kind(i)
            if k == .far && n - next > 14 && (i - next) % 2 == 1 { continue }   // 先の手が多いときは間引く
            let (p1, p2) = seg(i)
            let rr: CGFloat = k == .current ? max(14, cell * 0.2) : k == .near ? max(11, cell * 0.15) : max(8, cell * 0.11)
            var m = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            for t: CGFloat in [0.5, 0.32, 0.68, 0.2, 0.8] {
                let c = CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
                if placed.allSatisfy({ hypot($0.x - c.x, $0.y - c.y) > rr * 1.8 }) { m = c; break }
            }
            placed.append(m)
            let bg: UIColor = k == .current ? UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1) : k == .near ? .white : UIColor.white.withAlphaComponent(0.6)
            bg.setFill()
            g.fillEllipse(in: CGRect(x: m.x - rr, y: m.y - rr, width: rr * 2, height: rr * 2))
            g.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            g.setLineWidth(1.5)
            g.strokeEllipse(in: CGRect(x: m.x - rr, y: m.y - rr, width: rr * 2, height: rr * 2))
            label("\(i + 1)", at: m, size: rr * 1.15, color: UIColor(red: 0.08, green: 0.1, blue: 0.18, alpha: 1))
        }

        // 終わり（指を離す位置）
        let (_, endP) = seg(n - 1)
        let es = cell * 0.17
        UIColor.white.setFill()
        g.fill(CGRect(x: endP.x - es, y: endP.y - es, width: es * 2, height: es * 2))
        g.setStrokeColor(UIColor.black.cgColor)
        g.setLineWidth(2.5)
        g.stroke(CGRect(x: endP.x - es, y: endP.y - es, width: es * 2, height: es * 2))
        label("終", at: endP, size: es * 1.3, color: .black)

        // 開始位置 or 今の指の位置
        let here = next == 0 ? start : r.path[min(next, r.path.count - 1)]
        let hp = pt(Double(here % cols) + 0.5, Double(here / cols) + 0.5)
        let ringColor = next == 0 ? UIColor(red: 0.17, green: 0.86, blue: 0.56, alpha: 1) : UIColor(red: 0.2, green: 0.8, blue: 1, alpha: 1)
        g.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
        g.setLineWidth(max(8, cell * 0.13))
        g.strokeEllipse(in: CGRect(x: hp.x - cell * 0.46, y: hp.y - cell * 0.46, width: cell * 0.92, height: cell * 0.92))
        g.setStrokeColor(ringColor.cgColor)
        g.setLineWidth(max(5, cell * 0.09))
        g.strokeEllipse(in: CGRect(x: hp.x - cell * 0.46, y: hp.y - cell * 0.46, width: cell * 0.92, height: cell * 0.92))
        let tag = next == 0 ? "START" : "いま"
        let tagSize = max(10, cell * 0.17)
        let ty = hp.y - cell * 0.5 < origin.y + tagSize ? hp.y + cell * 0.52 : hp.y - cell * 0.62
        pill(tag, at: CGPoint(x: hp.x, y: ty), size: tagSize, bg: ringColor)

        // 次の数手を光る点がなぞる
        if let ph = phase, next < n {
            let segs = (next..<min(n, next + 3)).map { seg($0) }
            let lens = segs.map { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) }
            var d = lens.reduce(0, +) * ph
            var dot = segs[0].0
            for (k, s) in segs.enumerated() {
                if d <= lens[k] || k == segs.count - 1 {
                    let f = lens[k] > 0 ? min(1, d / lens[k]) : 0
                    dot = CGPoint(x: s.0.x + (s.1.x - s.0.x) * f, y: s.0.y + (s.1.y - s.0.y) * f)
                    break
                }
                d -= lens[k]
            }
            let rr = cell * 0.13
            UIColor.black.withAlphaComponent(0.6).setFill()
            g.fillEllipse(in: CGRect(x: dot.x - rr - 2, y: dot.y - rr - 2, width: rr * 2 + 4, height: rr * 2 + 4))
            UIColor(red: 1, green: 0.95, blue: 0.4, alpha: 1).setFill()
            g.fillEllipse(in: CGRect(x: dot.x - rr, y: dot.y - rr, width: rr * 2, height: rr * 2))
        }
    }

    /// 次の手順を矢印で並べた帯（小窓の上部）
    static func drawNextStrip(_ g: CGContext, result r: ResultMessage, progress: Int?, in rect: CGRect) {
        guard r.status == "ok", !r.moves.isEmpty else { return }
        let n = r.moves.count
        let next = nextStep(progress: progress, steps: n)
        let box = min(rect.height, (rect.width - 8) / 7)
        var x = rect.minX
        for i in next..<min(n, next + 7) {
            let b = CGRect(x: x, y: rect.minY, width: box - 6, height: box - 6)
            let path = UIBezierPath(roundedRect: b, cornerRadius: 10)
            (i == next ? UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1) : UIColor.white.withAlphaComponent(0.12)).setFill()
            path.fill()
            let arrow = Direction(rawValue: r.moves[i])?.arrow ?? "?"
            label(arrow, at: CGPoint(x: b.midX, y: b.midY + box * 0.04), size: box * 0.55,
                  color: i == next ? UIColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1) : .white, weight: .black)
            let num = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: box * 0.2, weight: .bold),
                                                        .foregroundColor: i == next ? UIColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 0.8) : UIColor.white.withAlphaComponent(0.7)]
            num.draw(at: CGPoint(x: b.minX + 5, y: b.minY + 2), withAttributes: attrs)
            x += box
        }
        if next >= n {
            label("ここで指を離す", at: CGPoint(x: rect.midX, y: rect.midY), size: rect.height * 0.4, color: .white, weight: .bold)
        }
    }

    // MARK: 部品

    static func stroke(_ g: CGContext, _ p1: CGPoint, _ p2: CGPoint, width: CGFloat, color: UIColor, outline: UIColor?) {
        if let o = outline {
            g.setStrokeColor(o.cgColor)
            g.setLineWidth(width + 4)
            g.move(to: p1); g.addLine(to: p2); g.strokePath()
        }
        g.setStrokeColor(color.cgColor)
        g.setLineWidth(width)
        g.move(to: p1); g.addLine(to: p2); g.strokePath()
    }

    static func arrowHead(_ g: CGContext, _ p1: CGPoint, _ p2: CGPoint, size s: CGFloat, color: UIColor) {
        let ang = atan2(p2.y - p1.y, p2.x - p1.x)
        let t = CGPoint(x: p1.x + (p2.x - p1.x) * 0.74, y: p1.y + (p2.y - p1.y) * 0.74)
        g.beginPath()
        g.move(to: CGPoint(x: t.x + s * cos(ang), y: t.y + s * sin(ang)))
        g.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang + 2.45), y: t.y + s * 0.8 * sin(ang + 2.45)))
        g.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang - 2.45), y: t.y + s * 0.8 * sin(ang - 2.45)))
        g.closePath()
        g.setFillColor(color.cgColor)
        g.setStrokeColor(UIColor.black.withAlphaComponent(0.75).cgColor)
        g.setLineWidth(2)
        g.drawPath(using: .fillStroke)
    }

    static func label(_ text: String, at c: CGPoint, size: CGFloat, color: UIColor, weight: UIFont.Weight = .heavy) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
    }

    static func pill(_ text: String, at c: CGPoint, size: CGFloat, bg: UIColor) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .black),
                                                    .foregroundColor: UIColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1)]
        let sz = s.size(withAttributes: attrs)
        let r = CGRect(x: c.x - sz.width / 2 - 6, y: c.y - sz.height / 2 - 2, width: sz.width + 12, height: sz.height + 4)
        bg.setFill()
        UIBezierPath(roundedRect: r, cornerRadius: r.height / 2).fill()
        s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2), withAttributes: attrs)
    }
}

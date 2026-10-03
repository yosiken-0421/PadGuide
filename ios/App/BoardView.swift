import SwiftUI
import PuzzleCore

/// 独自デザインのドロップ色
enum OrbStyle {
    static func color(_ k: OrbKind) -> Color {
        switch k {
        case .fire: return Color(red: 0.91, green: 0.28, blue: 0.24)
        case .water: return Color(red: 0.18, green: 0.55, blue: 0.92)
        case .wood: return Color(red: 0.18, green: 0.72, blue: 0.40)
        case .light: return Color(red: 0.96, green: 0.77, blue: 0.19)
        case .dark: return Color(red: 0.59, green: 0.33, blue: 0.84)
        case .heart: return Color(red: 0.95, green: 0.48, blue: 0.72)
        case .jammer: return Color(red: 0.72, green: 0.75, blue: 0.80)
        case .poison: return Color(red: 0.56, green: 0.42, blue: 0.66)
        case .mortalPoison: return Color(red: 0.29, green: 0.16, blue: 0.37)
        case .unknown: return Color(red: 0.36, green: 0.39, blue: 0.47)
        }
    }

    static func mark(_ k: OrbKind) -> String {
        switch k {
        case .heart: return "回"
        case .jammer: return "邪"
        case .mortalPoison: return "猛"
        case .unknown: return "?"
        default: return k.label
        }
    }
}

/// 盤面とルートの表示。マスをタップすると色を直せる。
struct BoardView: View {
    let board: Board
    let confidence: [Double]
    let result: ResultMessage?
    var onTapCell: ((Int) -> Void)?

    var body: some View {
        let cols = board.size.cols, rows = board.size.rows
        GeometryReader { geo in
            let cell = min(geo.size.width / CGFloat(cols), geo.size.height / CGFloat(rows))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    draw(ctx, cell: cell)
                }
                // タップ用の透明ボタン（読み上げにも対応）
                ForEach(0..<board.size.count, id: \.self) { i in
                    let r = i / cols, c = i % cols
                    Button { onTapCell?(i) } label: { Color.clear }
                        .frame(width: cell, height: cell)
                        .contentShape(Rectangle())
                        .offset(x: CGFloat(c) * cell, y: CGFloat(r) * cell)
                        .accessibilityIdentifier("cell-\(i)")
                        .accessibilityLabel("上から\(r + 1)段目、左から\(c + 1)列目、\(board.cells[i].label)")
                        .accessibilityHint("タップして色を直す")
                }
            }
            .frame(width: cell * CGFloat(cols), height: cell * CGFloat(rows))
        }
        .aspectRatio(CGFloat(cols) / CGFloat(rows), contentMode: .fit)
    }

    private func draw(_ ctx: GraphicsContext, cell: CGFloat) {
        let cols = board.size.cols
        for i in 0..<board.size.count {
            let r = CGFloat(i / cols), c = CGFloat(i % cols)
            let rect = CGRect(x: c * cell, y: r * cell, width: cell, height: cell)
            let even = (i / cols + i % cols) % 2 == 0
            let bg: Color = even ? Color(red: 0.16, green: 0.20, blue: 0.31) : Color(red: 0.18, green: 0.23, blue: 0.34)
            ctx.fill(Path(rect), with: .color(bg))
            let k = board.cells[i]
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: cell * 0.1, dy: cell * 0.1)), with: .color(OrbStyle.color(k)))
            ctx.draw(Text(OrbStyle.mark(k)).font(.system(size: cell * 0.3, weight: .heavy)).foregroundColor(.white),
                     at: CGPoint(x: rect.midX, y: rect.midY))
            let conf = i < confidence.count ? confidence[i] : 1
            if conf < BoardReading.lowConfidence || k == .unknown {   // 自信がないマスは黄色枠
                ctx.stroke(Path(rect.insetBy(dx: 2, dy: 2)), with: .color(.yellow), lineWidth: max(2, cell * 0.06))
            }
        }
        guard let res = result, res.status == "ok", !res.arrows.isEmpty, let start = res.start else { return }
        let n = res.arrows.count
        for (i, a) in res.arrows.enumerated() {
            let p1 = CGPoint(x: CGFloat(a[0]) * cell, y: CGFloat(a[1]) * cell)
            let p2 = CGPoint(x: CGFloat(a[2]) * cell, y: CGFloat(a[3]) * cell)
            let frac: Double = n > 1 ? Double(i) / Double(n - 1) : 0
            let hue: Double = (350.0 - 92.0 * frac) / 360.0
            let color = Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 1)
            var line = Path(); line.move(to: p1); line.addLine(to: p2)
            ctx.stroke(line, with: .color(.black.opacity(0.75)), style: StrokeStyle(lineWidth: cell * 0.12 + 3, lineCap: .round))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: cell * 0.12, lineCap: .round))
            let ang = atan2(p2.y - p1.y, p2.x - p1.x), s = cell * 0.2
            let t = CGPoint(x: p1.x + (p2.x - p1.x) * 0.72, y: p1.y + (p2.y - p1.y) * 0.72)
            var head = Path()
            head.move(to: CGPoint(x: t.x + s * cos(ang), y: t.y + s * sin(ang)))
            head.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang + 2.45), y: t.y + s * 0.8 * sin(ang + 2.45)))
            head.addLine(to: CGPoint(x: t.x + s * 0.8 * cos(ang - 2.45), y: t.y + s * 0.8 * sin(ang - 2.45)))
            head.closeSubpath()
            ctx.fill(head, with: .color(color))
        }
        let sc = CGPoint(x: (CGFloat(start % cols) + 0.5) * cell, y: (CGFloat(start / cols) + 0.5) * cell)
        ctx.stroke(Path(ellipseIn: CGRect(x: sc.x - cell * 0.46, y: sc.y - cell * 0.46, width: cell * 0.92, height: cell * 0.92)),
                   with: .color(.green), lineWidth: max(3, cell * 0.08))
        if let last = res.arrows.last {
            let e = CGPoint(x: CGFloat(last[2]) * cell, y: CGFloat(last[3]) * cell)
            let s = cell * 0.16
            let r = CGRect(x: e.x - s, y: e.y - s, width: s * 2, height: s * 2)
            ctx.fill(Path(r), with: .color(.white))
            ctx.stroke(Path(r), with: .color(.black), lineWidth: 2)
        }
    }
}

/// 開始位置と最初の手順の文章
enum RouteText {
    static func start(_ res: ResultMessage) -> String? {
        guard let s = res.start else { return nil }
        return "上から\(s / res.cols + 1)段目・左から\(s % res.cols + 1)列目"
    }

    static func firstMoves(_ res: ResultMessage, count: Int = 8) -> String {
        let arrows = res.moves.prefix(count).compactMap { Direction(rawValue: $0)?.arrow }
        return arrows.joined(separator: " ") + (res.moves.count > count ? " …" : "")
    }

    static func status(_ s: String) -> String {
        switch s {
        case "nocombo": return "この盤面ではコンボが見つかりませんでした"
        case "unstable": return "盤面が変化中です（操作中・ルーレットなど）。止まると計算します"
        case "dark": return "画面が暗いためルートを確定しません（暗闇など）"
        case "invalid": return "盤面が見つかりません。パズル画面を表示してください"
        default: return ""
        }
    }
}

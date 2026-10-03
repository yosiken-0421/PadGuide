import Foundation

/// 画面の画素を読むためのインターフェース（ReplayKit のフレームやテスト用の合成画像が実装する）
public protocol PixelSource {
    var width: Int { get }
    var height: Int { get }
    /// 0〜255 の RGB。範囲外の座標は呼び出し側で丸めない（実装側でクランプする）
    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)
}

public struct RGB: Codable, Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// (色相 0〜360, 彩度 0〜1, 明度 0〜1)
    public var hsv: (h: Double, s: Double, v: Double) {
        let r = Double(self.r) / 255, g = Double(self.g) / 255, b = Double(self.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    func distance(to o: RGB) -> Double {
        let dr = Double(r) - Double(o.r), dg = Double(g) - Double(o.g), db = Double(b) - Double(o.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// 手動修正から覚えた「この色はこのドロップ」という例（端末内だけに保存）
public struct LearnedSample: Codable, Equatable, Sendable {
    public var color: RGB
    public var kind: OrbKind
    public init(color: RGB, kind: OrbKind) { self.color = color; self.kind = kind }
}

/// 色の分類（HSV ＋ 手動修正の学習結果）
public struct ColorClassifier: Sendable {
    public static let maxLearned = 300
    public var learned: [LearnedSample]
    /// 学習例をそのまま採用する距離（RGB 空間）
    public var learnedRadius: Double = 26

    public init(learned: [LearnedSample] = []) { self.learned = learned }

    /// 修正を記録（古いものから捨てる）
    public mutating func learn(_ color: RGB, as kind: OrbKind) {
        learned.removeAll { $0.color.distance(to: color) < 8 }
        learned.append(LearnedSample(color: color, kind: kind))
        if learned.count > Self.maxLearned { learned.removeFirst(learned.count - Self.maxLearned) }
    }

    /// (種類, 信頼度 0〜1)
    public func classify(_ c: RGB) -> (OrbKind, Double) {
        if !learned.isEmpty {
            var best: LearnedSample?
            var bestD = Double.infinity
            for s in learned {
                let d = s.color.distance(to: c)
                if d < bestD { bestD = d; best = s }
            }
            if let b = best, bestD < learnedRadius { return (b.kind, 0.95) }
        }
        let (h, s, v) = c.hsv
        if v < 0.22 { return (.unknown, 0.3) }                     // 暗すぎる（暗闇など）
        if s < 0.20 {
            // 白〜灰色：お邪魔
            return v > 0.55 ? (.jammer, min(1, 0.55 + (0.20 - s) * 2)) : (.unknown, 0.3)
        }
        let colorful = min(1, s * 1.6) * min(1, v * 1.5)
        // 色相の境界付近は信頼度を下げる
        func edge(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
            let d = min(abs(x - lo), abs(hi - x))
            return 0.55 + 0.45 * min(1, d / 10)
        }
        let kind: OrbKind
        var conf: Double
        switch h {
        case 345..., ..<30:
            kind = .fire
            let hh = h >= 345 ? h - 360 : h
            conf = colorful * edge(hh, -15, 30)
        case 30..<72:
            kind = .light; conf = colorful * edge(h, 30, 72)
        case 72..<165:
            kind = .wood; conf = colorful * edge(h, 72, 165)
        case 165..<255:
            kind = .water; conf = colorful * edge(h, 165, 255)
        case 255..<300:
            if v < 0.45 { kind = .mortalPoison; conf = 0.6 * edge(h, 255, 300) }
            else if s < 0.45 { kind = .poison; conf = 0.6 * edge(h, 255, 300) }
            else { kind = .dark; conf = colorful * edge(h, 255, 300) }
        default:
            kind = .heart; conf = colorful * edge(h, 300, 345)
        }
        return (kind, conf)
    }
}

/// 1マスの認識結果
public struct CellReading: Codable, Equatable, Sendable {
    public var kind: OrbKind
    public var confidence: Double
    /// マス中央付近の平均色（手動修正の学習用。PC へは送らない）
    public var color: RGB
}

/// 画面上の盤面の位置（ピクセル）
public struct BoardRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, cell: Double
    public var size: BoardSize
    public init(x: Double, y: Double, cell: Double, size: BoardSize) {
        self.x = x; self.y = y; self.cell = cell; self.size = size
    }
    public var width: Double { cell * Double(size.cols) }
    public var height: Double { cell * Double(size.rows) }
}

public struct BoardReading: Codable, Equatable, Sendable {
    public var rect: BoardRect
    public var cells: [CellReading]
    public var brightness: Double

    public var size: BoardSize { rect.size }
    public var board: Board { Board(size: rect.size, cells: cells.map { $0.kind }) }
    public var averageConfidence: Double {
        cells.isEmpty ? 0 : cells.reduce(0) { $0 + $1.confidence } / Double(cells.count)
    }
    public var unknownCount: Int { cells.filter { $0.kind == .unknown }.count }
    public static let lowConfidence = 0.5
    public var lowConfidenceIndices: [Int] {
        cells.indices.filter { cells[$0].confidence < Self.lowConfidence }
    }
    /// 暗闇・超暗闇などで画面が暗い
    public var isDark: Bool { brightness < 0.2 }
    /// ルートを確定してよい状態か（暗い・不明が多い・信頼度が低いときは確定しない）
    public var isUsable: Bool {
        !isDark && averageConfidence >= 0.55 && unknownCount <= max(2, cells.count / 10)
    }
}

public enum BoardReader {
    /// マス中央付近を 3×3 点サンプリングし、信頼度で重み付けした多数決で決める。
    /// 強化マーク・ロック・模様が一部の点に重なっても、基礎色が多数派になる。
    public static func read(_ src: PixelSource, rect: BoardRect, classifier: ColorClassifier) -> BoardReading {
        let size = rect.size
        let offsets: [Double] = [-0.2, 0, 0.2]
        let patch = max(1, Int(rect.cell * 0.035))
        var cells: [CellReading] = []
        cells.reserveCapacity(size.count)
        var vSum = 0.0
        for r in 0..<size.rows {
            for c in 0..<size.cols {
                var votes = [Double](repeating: 0, count: OrbKind.allCases.count)
                var counts = [Int](repeating: 0, count: OrbKind.allCases.count)
                var total = 0.0
                var cr = 0, cg = 0, cb = 0, n = 0
                for oy in offsets {
                    for ox in offsets {
                        let x = Int(rect.x + (Double(c) + 0.5 + ox) * rect.cell)
                        let y = Int(rect.y + (Double(r) + 0.5 + oy) * rect.cell)
                        let col = average(src, x, y, patch)
                        let (k, conf) = classifier.classify(col)
                        votes[Int(k.rawValue)] += max(conf, 0.05)
                        counts[Int(k.rawValue)] += 1
                        total += max(conf, 0.05)
                        cr += Int(col.r); cg += Int(col.g); cb += Int(col.b); n += 1
                    }
                }
                // 不明以外で最も票の多い種類
                var best = Int(OrbKind.unknown.rawValue)
                var bestV = 0.0
                for k in 0..<votes.count where k != Int(OrbKind.unknown.rawValue) && votes[k] > bestV {
                    best = k; bestV = votes[k]
                }
                // 信頼度 = 票の割合 × 勝った点の色のはっきりさ
                let share = total > 0 ? bestV / total : 0
                let winnerAvg = counts[best] > 0 ? bestV / Double(counts[best]) : 0
                let conf = min(1, share * (0.4 + 0.6 * winnerAvg))
                let avg = RGB(UInt8(cr / n), UInt8(cg / n), UInt8(cb / n))
                vSum += avg.hsv.v
                let kind: OrbKind = conf < 0.35 ? .unknown : OrbKind(rawValue: Int8(best)) ?? .unknown
                cells.append(CellReading(kind: kind, confidence: (conf * 100).rounded() / 100, color: avg))
            }
        }
        return BoardReading(rect: rect, cells: cells, brightness: vSum / Double(max(1, size.count)))
    }

    static func average(_ src: PixelSource, _ cx: Int, _ cy: Int, _ r: Int) -> RGB {
        var rs = 0, gs = 0, bs = 0, n = 0
        let step = max(1, r / 2)
        var y = cy - r
        while y <= cy + r {
            var x = cx - r
            while x <= cx + r {
                let p = src.rgb(min(max(x, 0), src.width - 1), min(max(y, 0), src.height - 1))
                rs += Int(p.0); gs += Int(p.1); bs += Int(p.2); n += 1
                x += step
            }
            y += step
        }
        return RGB(UInt8(rs / n), UInt8(gs / n), UInt8(bs / n))
    }
}

public enum BoardDetector {
    /// 盤面候補を探す。画面下部を中心に、規則的に丸いドロップが並ぶ位置とサイズを選ぶ。
    /// - Parameter fixedSize: 手動でサイズを選んだ場合はそのサイズだけを試す
    public static func detect(_ src: PixelSource, fixedSize: BoardSize? = nil,
                              classifier: ColorClassifier = ColorClassifier()) -> BoardReading? {
        let sizes = fixedSize.map { [$0] } ?? BoardSize.supported
        let W = Double(src.width), H = Double(src.height)
        var best: (score: Double, rect: BoardRect)?

        for size in sizes {
            for inset in [0.0, 0.02, 0.04] {
                let width = W * (1 - inset * 2)
                let cell = width / Double(size.cols)
                let h = cell * Double(size.rows)
                let x = W * inset
                // 画面の下 75% を粗く走査
                let step = max(2, cell / 10)
                var y = H * 0.25
                var localBest: (Double, Double)? = nil
                while y + h <= H {
                    let s = gridScore(src, BoardRect(x: x, y: y, cell: cell, size: size))
                    if localBest == nil || s > localBest!.0 { localBest = (s, y) }
                    y += step
                }
                guard let lb = localBest else { continue }
                var s0 = lb.0, y0 = lb.1
                // 細かく合わせ込む
                var yy = max(0, y0 - step)
                while yy <= min(H - h, y0 + step) {
                    let s = gridScore(src, BoardRect(x: x, y: yy, cell: cell, size: size))
                    if s > s0 { s0 = s; y0 = yy }
                    yy += 1
                }
                let rect = BoardRect(x: x, y: y0, cell: cell, size: size)
                if best == nil || s0 > best!.score { best = (s0, rect) }
            }
        }
        guard let b = best else { return nil }
        let reading = BoardReader.read(src, rect: b.rect, classifier: classifier)
        return reading.isUsable ? reading : nil
    }

    /// マスの中が鮮やか・マスの角（ドロップの外側）が暗いほど高い。1マスあたりの平均値。
    static func gridScore(_ src: PixelSource, _ rect: BoardRect) -> Double {
        let size = rect.size
        var s = 0.0
        for r in 0..<size.rows {
            for c in 0..<size.cols {
                let x0 = rect.x + Double(c) * rect.cell
                let y0 = rect.y + Double(r) * rect.cell
                var inner = 0.0
                for (fx, fy) in [(0.32, 0.32), (0.68, 0.68), (0.5, 0.5), (0.32, 0.68)] {
                    let p = src.rgb(clampX(src, x0 + rect.cell * fx), clampY(src, y0 + rect.cell * fy))
                    let hsv = RGB(p.0, p.1, p.2).hsv
                    inner += max(hsv.s, 0.25) * hsv.v
                }
                // マスの辺の中点（ドロップの外側）。位置がずれるとここが隣のドロップに重なって明るくなる
                var outer = 0.0
                for (fx, fy) in [(0.5, 0.03), (0.03, 0.5), (0.97, 0.5), (0.5, 0.97)] {
                    let p = src.rgb(clampX(src, x0 + rect.cell * fx), clampY(src, y0 + rect.cell * fy))
                    outer += RGB(p.0, p.1, p.2).hsv.v
                }
                s += inner / 4 - outer / 4 * 0.9
            }
        }
        return s / Double(size.count)
    }

    private static func clampX(_ src: PixelSource, _ x: Double) -> Int { min(max(Int(x), 0), src.width - 1) }
    private static func clampY(_ src: PixelSource, _ y: Double) -> Int { min(max(Int(y), 0), src.height - 1) }
}

/// 同じ盤面が続いたら確定する（ルーレットのように変化し続ける間は確定しない）
public struct BoardStabilizer: Sendable {
    public let requiredFrames: Int
    private var last: [OrbKind]?
    private var count = 0

    public init(requiredFrames: Int = 2) { self.requiredFrames = requiredFrames }

    /// 確定した盤面なら true
    public mutating func feed(_ cells: [OrbKind]) -> Bool {
        if cells == last { count += 1 } else { last = cells; count = 1 }
        return count >= requiredFrames
    }

    public mutating func reset() { last = nil; count = 0 }
}

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
    /// 各色ドロップの基準の色相（度）。盤面ごとに実際の色へ合わせ直す。
    static let prototypeHue: [OrbKind: Double] = [
        .fire: 8, .light: 50, .wood: 130, .water: 205, .dark: 282, .heart: 330,
    ]
    static let colorKinds: [OrbKind] = [.fire, .water, .wood, .light, .dark, .heart]

    /// 1マスの特徴（ドロップの内側だけを見る）
    struct CellFeature {
        var hue: Double?          // 鮮やかな画素の平均色相（なければ nil）
        var colorfulRatio: Double // 鮮やかな画素の割合
        var greyBrightRatio: Double
        /// 彩度の低い（灰色〜青みがかった灰色）画素の割合。暗い縁や模様は除く
        var greyRatio: Double
        var meanV: Double
        var meanS: Double
        var hueSpread: Double     // 色相のばらつき（0=そろっている〜1）
        var color: RGB
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// ドロップの内側を同心円状にサンプリングする。
    /// - 光沢（白いハイライト）や強化マーク・ロックの模様は「鮮やかでない画素」として除外し、基礎色だけを見る
    /// - 縁の影で暗い画素も除外する
    static func feature(_ src: PixelSource, cx: Double, cy: Double, cell: Double) -> CellFeature {
        let patch = max(1, Int(cell * 0.02))
        var sx = 0.0, sy = 0.0, wsum = 0.0
        var colorful = 0, greyBright = 0, grey = 0, total = 0
        var vs = 0.0, ss = 0.0
        var cr = 0, cg = 0, cb = 0, cn = 0
        let rings: [(Double, Int)] = [(0.0, 1), (0.1, 6), (0.19, 8), (0.28, 10), (0.35, 12)]
        for (radius, count) in rings {
            for k in 0..<count {
                let ang = (Double(k) + (radius == 0.19 || radius == 0.35 ? 0.5 : 0)) / Double(count) * 2 * Double.pi
                let x = Int(cx + cos(ang) * radius * cell)
                let y = Int(cy + sin(ang) * radius * cell)
                let c = average(src, x, y, patch)
                let (h, sat, v) = c.hsv
                total += 1
                if sat >= 0.30 && v >= 0.22 {
                    colorful += 1
                    let w = sat * v
                    sx += cos(h * Double.pi / 180) * w
                    sy += sin(h * Double.pi / 180) * w
                    wsum += w
                    vs += v; ss += sat
                    cr += Int(c.r); cg += Int(c.g); cb += Int(c.b); cn += 1
                } else if sat < 0.24 && v > 0.55 {
                    greyBright += 1
                }
                if sat < 0.30 && v >= 0.30 { grey += 1 }
            }
        }
        var hue: Double?
        var spread = 1.0
        if wsum > 0 {
            var h = atan2(sy, sx) * 180 / Double.pi
            if h < 0 { h += 360 }
            hue = h
            spread = 1 - min(1, (sx * sx + sy * sy).squareRoot() / wsum)
        }
        let color = cn > 0 ? RGB(UInt8(cr / cn), UInt8(cg / cn), UInt8(cb / cn)) : average(src, Int(cx), Int(cy), patch)
        return CellFeature(hue: hue, colorfulRatio: Double(colorful) / Double(total),
                           greyBrightRatio: Double(greyBright) / Double(total),
                           greyRatio: Double(grey) / Double(total),
                           meanV: colorful > 0 ? vs / Double(colorful) : color.hsv.v,
                           meanS: colorful > 0 ? ss / Double(colorful) : color.hsv.s,
                           hueSpread: spread, color: color)
    }

    /// 色相から最も近い色ドロップ
    static func nearestKind(_ hue: Double, centers: [OrbKind: Double]) -> (OrbKind, Double, Double) {
        var best = OrbKind.unknown, bestD = 999.0, second = 999.0
        for k in colorKinds {
            let d = hueDistance(hue, centers[k] ?? prototypeHue[k]!)
            if d < bestD { second = bestD; bestD = d; best = k }
            else if d < second { second = d }
        }
        return (best, bestD, second)
    }

    /// 盤面を読む。
    /// 1. 各マスのドロップの内側から、鮮やかな画素の平均色相を求める（光沢・模様・影は除外）
    /// 2. 基準の色相で仮に分類し、その盤面での各色の実際の色相に合わせ直して分類し直す（色味のずれに強い）
    /// 3. 手動修正で覚えた色があれば、それを優先する
    public static func read(_ src: PixelSource, rect: BoardRect, classifier: ColorClassifier) -> BoardReading {
        let size = rect.size
        var feats: [CellFeature] = []
        feats.reserveCapacity(size.count)
        for r in 0..<size.rows {
            for c in 0..<size.cols {
                let cx = rect.x + (Double(c) + 0.5) * rect.cell
                let cy = rect.y + (Double(r) + 0.5) * rect.cell
                feats.append(feature(src, cx: cx, cy: cy, cell: rect.cell))
            }
        }

        // その盤面での各色の中心色相を求める（基準から大きくずれない範囲で）
        var centers = prototypeHue
        for _ in 0..<2 {
            var acc: [OrbKind: (Double, Double, Int)] = [:]
            for f in feats {
                guard let h = f.hue, f.colorfulRatio >= 0.45 else { continue }
                let (k, d, second) = nearestKind(h, centers: centers)
                guard d < 30, second - d > 12 else { continue }
                let e = acc[k] ?? (0, 0, 0)
                acc[k] = (e.0 + cos(h * Double.pi / 180), e.1 + sin(h * Double.pi / 180), e.2 + 1)
            }
            for (k, e) in acc where e.2 >= 2 {
                var h = atan2(e.1, e.0) * 180 / Double.pi
                if h < 0 { h += 360 }
                if hueDistance(h, prototypeHue[k]!) <= 25 { centers[k] = h }
            }
        }

        // その盤面での色ドロップの典型的な彩度（お邪魔のくすんだ色と見分けるため）
        let vivid = feats.filter { $0.hue != nil && $0.colorfulRatio >= 0.45 }.map { $0.meanS }.sorted()
        let typicalS = vivid.count >= 6 ? vivid[vivid.count / 2] : 0.7
        let dullLimit = min(0.45, typicalS * 0.62)

        var cells: [CellReading] = []
        cells.reserveCapacity(size.count)
        var vSum = 0.0
        for f in feats {
            vSum += f.meanV
            // 手動修正で覚えた色を優先
            if !classifier.learned.isEmpty {
                let (k, conf) = classifier.classify(f.color)
                if conf >= 0.95 {
                    cells.append(CellReading(kind: k, confidence: conf, color: f.color))
                    continue
                }
            }
            var kind = OrbKind.unknown
            var conf = 0.0
            if let h = f.hue, f.colorfulRatio >= 0.35 {
                let (k, d, second) = nearestKind(h, centers: centers)
                kind = k
                // 近さ・他の色との差・色のそろい具合・鮮やかな画素の割合から信頼度を決める
                let near = max(0, 1 - d / 45)
                let margin = min(1, max(0, second - d) / 40)
                let uniform = max(0, 1 - f.hueSpread * 2.5)
                let coverage = min(1, f.colorfulRatio / 0.6)
                conf = min(1, 0.25 + 0.75 * (0.35 * near + 0.25 * margin + 0.2 * uniform + 0.2 * coverage))
                if d > 40 { conf = min(conf, 0.3) }
                // 紫系のうち、とても暗いものは猛毒、くすんだものは毒の可能性（自信は低めにして黄色枠で知らせる。
                // 手動で直すとその色を覚える）。通常の闇ドロップは鮮やかで明るい
                if kind == .dark && f.meanV < 0.42 { kind = .mortalPoison; conf = min(conf, 0.55) }
                else if kind == .dark && f.meanS < 0.42 { kind = .poison; conf = min(conf, 0.55) }
                // お邪魔ドロップ：青みがかった灰色。鮮やかな画素があっても彩度がとても低ければ色ドロップではない
                // （水・木などの色ドロップは鮮やか。紫系のくすんだ色は毒として上で扱う）
                else if isDullJammer(f, dullLimit: dullLimit) {
                    kind = .jammer
                    conf = min(0.9, 0.6 + f.greyRatio * 0.3 + max(0, dullLimit - f.meanS))
                }
            } else if f.greyRatio >= 0.4 || f.greyBrightRatio >= 0.5 {
                // 灰色が多い：お邪魔（明るさによらない。陰影や暗い模様があっても読めるように）
                kind = .jammer
                conf = min(0.95, 0.45 + max(f.greyRatio, f.greyBrightRatio) * 0.5)
            } else {
                kind = .unknown
                conf = 0.2
            }
            if conf < 0.35 { kind = .unknown }
            cells.append(CellReading(kind: kind, confidence: (conf * 100).rounded() / 100, color: f.color))
        }
        return BoardReading(rect: rect, cells: cells, brightness: vSum / Double(max(1, size.count)))
    }

    /// 彩度の低い色のマスをお邪魔と判断するか（紫系＝毒・猛毒は除く）
    static func isDullJammer(_ f: CellFeature, dullLimit: Double) -> Bool {
        guard let h = f.hue, !(255..<300).contains(h) else { return false }
        if f.meanS < 0.36 { return true }
        // 青〜緑がかった灰色（お邪魔によくある色味）は、盤面の色ドロップより明らかにくすんでいればお邪魔
        return (150..<260).contains(h) && f.meanS < dullLimit
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
            for inset in [0.0, 0.01, 0.02, 0.03, 0.045] {
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
                // ドロップの外側（マスの角と辺の中点）。位置がずれるとここが隣のドロップに重なって明るくなる
                var outer = 0.0
                for (fx, fy) in [(0.5, 0.03), (0.03, 0.5), (0.97, 0.5), (0.5, 0.97),
                                 (0.07, 0.07), (0.93, 0.07), (0.07, 0.93), (0.93, 0.93)] {
                    let p = src.rgb(clampX(src, x0 + rect.cell * fx), clampY(src, y0 + rect.cell * fy))
                    outer += RGB(p.0, p.1, p.2).hsv.v
                }
                s += inner / 4 - outer / 8 * 0.9
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
    /// 連続するフレームの間で、違ってよいマス数（光る演出・持っているドロップなどのちらつき）
    public let flickerTolerance: Int
    private var recent: [[OrbKind]] = []
    /// 確定した盤面（直近のフレームのマスごとの多数決）
    public private(set) var consensus: [OrbKind]?

    public init(requiredFrames: Int = 2, flickerTolerance: Int = 1) {
        self.requiredFrames = requiredFrames
        self.flickerTolerance = flickerTolerance
    }

    /// 直近のフレームがほぼ同じなら確定して true（ルーレットのように変化し続ける間は確定しない）
    public mutating func feed(_ cells: [OrbKind]) -> Bool {
        if let last = recent.last, last.count != cells.count { recent.removeAll() }
        recent.append(cells)
        if recent.count > requiredFrames { recent.removeFirst(recent.count - requiredFrames) }
        guard recent.count == requiredFrames else { consensus = nil; return false }
        for a in 0..<recent.count {
            for b in (a + 1)..<recent.count where Self.mismatch(recent[a], recent[b]) > flickerTolerance {
                consensus = nil
                return false
            }
        }
        // マスごとの多数決（同数なら新しいフレーム）
        var out = cells
        for i in cells.indices {
            var tally: [OrbKind: Int] = [:]
            for f in recent { tally[f[i], default: 0] += 1 }
            let top = tally.values.max() ?? 0
            if let pick = recent.reversed().first(where: { tally[$0[i]] == top }) { out[i] = pick[i] }
        }
        consensus = out
        return true
    }

    public mutating func reset() { recent.removeAll(); consensus = nil }

    static func mismatch(_ a: [OrbKind], _ b: [OrbKind]) -> Int {
        guard a.count == b.count else { return Int.max }
        var n = 0
        for i in a.indices where a[i] != b[i] { n += 1 }
        return n
    }
}

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
    /// 黒く覆われて色が見えないドロップ（暗闇など）。色は「不明」だが、読み取りの失敗ではない
    public var covered: Bool?
    /// 雲に隠れたドロップ（白い雲が上にかぶさって色が見えない）。covered も true にする
    public var cloud: Bool?

    public init(kind: OrbKind, confidence: Double, color: RGB, covered: Bool? = nil, cloud: Bool? = nil) {
        self.kind = kind; self.confidence = confidence; self.color = color; self.covered = covered; self.cloud = cloud
    }
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
    /// 盤面全体が暗く・色が薄くなっている（敵の行動中などでパズルできない状態）。この間はルートを出さない
    public var dimmed: Bool? = nil
    /// 操作不可（テープ）が貼られたマス。画面の帯から自動で見つける（なければ nil）
    public var taped: [Int]? = nil

    public var size: BoardSize { rect.size }
    public var board: Board { Board(size: rect.size, cells: cells.map { $0.kind }) }
    public var averageConfidence: Double {
        cells.isEmpty ? 0 : cells.reduce(0) { $0 + $1.confidence } / Double(cells.count)
    }
    public var unknownCount: Int { cells.filter { $0.kind == .unknown }.count }
    /// 黒く覆われたドロップ（暗闇など）の数
    public var coveredCount: Int { cells.filter { $0.covered == true }.count }
    /// 読み取りに失敗した不明マスの数（覆われたドロップは数えない）
    public var uncertainCount: Int { cells.filter { $0.kind == .unknown && $0.covered != true }.count }
    /// ほとんど真っ白なマスの割合（メニュー・演出などの白い画面を盤面と間違えないため）
    public var whiteFraction: Double {
        guard !cells.isEmpty else { return 0 }
        let n = cells.filter { let h = $0.color.hsv; return h.s < 0.08 && h.v > 0.85 }.count
        return Double(n) / Double(cells.count)
    }
    public static let lowConfidence = 0.5
    public var lowConfidenceIndices: [Int] {
        cells.indices.filter { cells[$0].confidence < Self.lowConfidence }
    }
    /// 暗闇・超暗闇などで画面が暗い
    public var isDark: Bool { brightness < 0.2 }
    /// ルートを確定してよい状態か（暗い・不明が多い・信頼度が低いときは確定しない）
    public var isUsable: Bool {
        !isDark && dimmed != true && averageConfidence >= 0.55 && uncertainCount <= max(2, cells.count / 10) && whiteFraction <= 0.6
            && Double(coveredCount) <= Double(cells.count) * 0.7
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
        /// 灰色っぽい画素も含めた、わずかな色味の色相（青み＝お邪魔、紫み＝毒の見分け用）
        var tintHue: Double?
        /// ドロップ全体（暗い縁を除く）の平均彩度
        var bodyS: Double
        /// とても暗い画素の割合（黒く覆われたドロップの見分け用）
        var darkRatio: Double
        /// ドロップ全体（暗い縁を除く）の平均の明るさ
        var bodyV: Double
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
    /// - satMin: 「鮮やかな画素」とみなす彩度。画面全体の色が薄い盤面では下げる（盤面ごとに決める）
    static func feature(_ src: PixelSource, cx: Double, cy: Double, cell: Double, satMin: Double = 0.30,
                        points: [(Double, Double)]? = nil) -> CellFeature {
        let patch = max(1, Int(cell * 0.02))
        // 見る位置（マスの中心からのずれ。マスの大きさを 1 とする）。ふつうは同心円状、テープのマスは見えている所だけ
        var offsets: [(Double, Double)] = []
        if let points {
            offsets = points
        } else {
            let rings: [(Double, Int)] = [(0.0, 1), (0.1, 6), (0.19, 8), (0.28, 10), (0.35, 12)]
            for (radius, count) in rings {
                for k in 0..<count {
                    let ang = (Double(k) + (radius == 0.19 || radius == 0.35 ? 0.5 : 0)) / Double(count) * 2 * Double.pi
                    offsets.append((cos(ang) * radius, sin(ang) * radius))
                }
            }
        }
        var sx = 0.0, sy = 0.0, wsum = 0.0
        var colorful = 0, greyBright = 0, grey = 0, total = 0
        var vs = 0.0, ss = 0.0
        var cr = 0, cg = 0, cb = 0, cn = 0
        var tx = 0.0, ty = 0.0, tw = 0.0
        var bodyS = 0.0, bodyV = 0.0, bodyN = 0, dark = 0
        var gr = 0, gg = 0, gb = 0, gn = 0
        do {
            for (ox, oy) in offsets {
                let x = Int(cx + ox * cell)
                let y = Int(cy + oy * cell)
                let c = average(src, x, y, patch)
                let (h, sat, v) = c.hsv
                total += 1
                if sat >= satMin && v >= 0.22 {
                    colorful += 1
                    let w = sat * v
                    sx += cos(h * Double.pi / 180) * w
                    sy += sin(h * Double.pi / 180) * w
                    wsum += w
                    vs += v; ss += sat
                    cr += Int(c.r); cg += Int(c.g); cb += Int(c.b); cn += 1
                } else if sat < min(0.24, satMin * 0.8) && v > 0.55 {
                    greyBright += 1
                }
                if sat < satMin && v >= 0.30 { grey += 1 }
                if v >= 0.30 && sat >= 0.08 {
                    tx += cos(h * Double.pi / 180) * sat
                    ty += sin(h * Double.pi / 180) * sat
                    tw += sat
                }
                if v >= 0.22 { bodyS += sat; bodyV += v; bodyN += 1 } else { dark += 1 }
                if v >= 0.30 { gr += Int(c.r); gg += Int(c.g); gb += Int(c.b); gn += 1 }
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
        var tint: Double?
        if tw > 0 {
            var t = atan2(ty, tx) * 180 / Double.pi
            if t < 0 { t += 360 }
            tint = t
        }
        // 代表色（手動修正の学習に使う）：色ドロップは鮮やかな画素の平均、灰色っぽいドロップは模様・縁を除いた全体の平均
        let colorfulShare = Double(colorful) / Double(total)
        let color: RGB
        if cn > 0 && colorfulShare >= 0.35 {
            color = RGB(UInt8(cr / cn), UInt8(cg / cn), UInt8(cb / cn))
        } else if gn > 0 {
            color = RGB(UInt8(gr / gn), UInt8(gg / gn), UInt8(gb / gn))
        } else if cn > 0 {
            color = RGB(UInt8(cr / cn), UInt8(cg / cn), UInt8(cb / cn))
        } else {
            color = average(src, Int(cx), Int(cy), patch)
        }
        return CellFeature(hue: hue, colorfulRatio: Double(colorful) / Double(total),
                           greyBrightRatio: Double(greyBright) / Double(total),
                           greyRatio: Double(grey) / Double(total),
                           tintHue: tint, bodyS: bodyN > 0 ? bodyS / Double(bodyN) : 0, darkRatio: Double(dark) / Double(total),
                           bodyV: bodyN > 0 ? bodyV / Double(bodyN) : 0,
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
        // 操作不可（テープ）：行・列をまたぐ帯が貼られたマスは、帯に隠れていない所だけで色を読む
        let bands = tapeBands(src, rect: rect)
        var tapePoints: [Int: [(Double, Double)]] = [:]
        for r in 0..<size.rows {
            for c in 0..<size.cols {
                let mine = bands.filter { $0.vertical ? $0.index == c : $0.index == r }
                if !mine.isEmpty { tapePoints[r * size.cols + c] = visiblePoints(excluding: mine) }
            }
        }
        func features(_ satMin: Double) -> [CellFeature] {
            var out: [CellFeature] = []
            out.reserveCapacity(size.count)
            for r in 0..<size.rows {
                for c in 0..<size.cols {
                    let cx = rect.x + (Double(c) + 0.5) * rect.cell
                    let cy = rect.y + (Double(r) + 0.5) * rect.cell
                    let pts = tapePoints[r * size.cols + c]
                    out.append(feature(src, cx: cx, cy: cy, cell: rect.cell, satMin: satMin,
                                       points: pts.flatMap { $0.count >= 8 ? $0 : nil }))
                }
            }
            return out
        }
        var feats = features(0.30)
        // 画面全体の色が薄い（彩度が低い）盤面では、「鮮やか」の基準をその盤面に合わせて下げて読み直す。
        // 決まった基準のままだと、色ドロップをお邪魔・毒・不明と読み違える
        let bodySat = feats.map { $0.bodyS }.sorted()
        let satMin = min(0.30, max(0.14, bodySat[bodySat.count / 2] * 0.55))
        if satMin < 0.30 { feats = features(satMin) }

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
        // 紫系（闇・毒・猛毒）は、その盤面の鮮やかな闇ドロップと比べて見分ける
        // （くすんでいれば毒、暗ければ猛毒。闇ドロップがない盤面では決まった値で判断）
        let darkRefs = feats.filter {
            guard let h = $0.hue else { return false }
            return $0.colorfulRatio >= 0.45 && (255..<300).contains(h) && $0.meanS >= min(0.55, typicalS * 0.8) && $0.meanV >= 0.5
        }
        var poisonS = min(0.5, typicalS * 0.75), mortalV = 0.42
        if darkRefs.count >= 2 {
            let dS = darkRefs.map { $0.meanS }.sorted()[darkRefs.count / 2]
            let dV = darkRefs.map { $0.meanV }.sorted()[darkRefs.count / 2]
            poisonS = min(0.5, dS * 0.78)
            mortalV = min(0.5, dV * 0.65)
        }

        var cells: [CellReading] = []
        cells.reserveCapacity(size.count)
        var learnedHit = Set<Int>()   // 手動修正で覚えた色で決めたマス（あとから変えない）
        var vSum = 0.0
        for f in feats {
            vSum += f.meanV
            // テープが縦横に重なって、ドロップがほとんど見えないマス：色は分からないが、ドロップはある
            if let pts = tapePoints[cells.count], pts.count < 8 {
                cells.append(CellReading(kind: .unknown, confidence: 0.9, color: f.color, covered: true))
                continue
            }
            // 雲：ほとんど白で色味がない（実機：彩度 0.04〜0.06・明るさ 0.85）。ドロップの色は見えないが、ドロップはある。
            // 動かせるが消えないものとして計算する（お邪魔は青みがかった灰色〜紺色で、ここまで白く明るくない）
            if f.bodyS < 0.12 && f.bodyV > 0.72 && f.greyBrightRatio >= 0.7 {
                cells.append(CellReading(kind: .unknown, confidence: 0.9, color: f.color, covered: true, cloud: true))
                continue
            }
            // 手動修正で覚えた色を優先
            if !classifier.learned.isEmpty {
                let (k, conf) = classifier.classify(f.color)
                if conf >= 0.95 {
                    learnedHit.insert(cells.count)
                    cells.append(CellReading(kind: k, confidence: conf, color: f.color))
                    continue
                }
            }
            var kind = OrbKind.unknown
            var conf = 0.0
            if f.darkRatio >= 0.6 && f.colorfulRatio < 0.2 {
                // 黒く覆われたドロップ（暗闇など）：色は分からないが、ドロップはある。動かせるが消えないものとして計算する
                cells.append(CellReading(kind: .unknown, confidence: 0.9, color: f.color, covered: true))
                continue
            } else if let h = f.hue, f.colorfulRatio >= 0.35 {
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
                if kind == .dark && f.meanV < mortalV { kind = .mortalPoison; conf = min(conf, 0.55) }
                else if kind == .dark && f.meanS < poisonS { kind = .poison; conf = min(conf, 0.55) }
                // お邪魔ドロップ：青みがかった灰色。鮮やかな画素があっても彩度がとても低ければ色ドロップではない
                // （水・木などの色ドロップは鮮やか。紫系のくすんだ色は毒として上で扱う）
                else if isDullJammer(f, dullLimit: dullLimit) {
                    kind = .jammer
                    conf = min(0.9, 0.6 + f.greyRatio * 0.3 + max(0, dullLimit - f.meanS))
                }
            } else if (f.greyRatio >= 0.4 || f.greyBrightRatio >= 0.5), let t = f.tintHue, (250..<310).contains(t), f.bodyS >= 0.12 {
                // 灰色っぽいが紫みがある：毒（お邪魔は青みがかった灰色）。自信は低めにして黄色枠で知らせる
                kind = .poison
                conf = 0.5
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

        // お邪魔は青みがかった色のことがあり、水と間違えやすい。
        // 1. 青系のマスが「鮮やかな水」と「くすんだ青」の2つにはっきり分かれていれば、くすんだ方はお邪魔
        let blue = cells.indices.filter { cells[$0].kind == .water && !learnedHit.contains($0) }
        if blue.count >= 2 {
            let sorted = blue.map { (feats[$0].meanS, $0) }.sorted { $0.0 < $1.0 }
            var gap = 0.0, at = -1
            for j in 0..<(sorted.count - 1) where sorted[j + 1].0 - sorted[j].0 > gap {
                gap = sorted[j + 1].0 - sorted[j].0; at = j
            }
            if at >= 0 {
                let upper = sorted[(at + 1)...].map { $0.0 }
                let upperMean = upper.reduce(0, +) / Double(upper.count)
                if gap >= 0.12 && sorted[at].0 <= 0.55 && upperMean >= 0.55 {
                    for (_, i) in sorted[...at] { cells[i].kind = .jammer; cells[i].confidence = 0.6 }
                }
            }
        }
        // 2. 明るさでも分ける：実機のお邪魔は紺色で暗い（明るさ 0.4 前後）。水は明るい（0.8 前後）。色相はほぼ同じ
        let blue2 = cells.indices.filter { cells[$0].kind == .water && !learnedHit.contains($0) }
        if blue2.count >= 2 {
            let sorted = blue2.map { (feats[$0].meanV, $0) }.sorted { $0.0 < $1.0 }
            var gap = 0.0, at = -1
            for j in 0..<(sorted.count - 1) where sorted[j + 1].0 - sorted[j].0 > gap {
                gap = sorted[j + 1].0 - sorted[j].0; at = j
            }
            if at >= 0 {
                let upper = sorted[(at + 1)...].map { $0.0 }
                let upperMean = upper.reduce(0, +) / Double(upper.count)
                if gap >= 0.2 && sorted[at].0 <= 0.6 && upperMean >= 0.65 {
                    for (_, i) in sorted[...at] { cells[i].kind = .jammer; cells[i].confidence = 0.85 }
                }
            }
        }
        // 水がない盤面でも：盤面の色ドロップの典型的な明るさよりはっきり暗い青はお邪魔
        // 基準の明るさは青系以外の色ドロップで決める（お邪魔が多い盤面で、お邪魔自身が基準を下げないように）
        let vivV = feats.filter {
            guard let h = $0.hue else { return false }
            return $0.colorfulRatio >= 0.45 && !(180..<250).contains(h)
        }.map { $0.meanV }.sorted()
        let typicalV = vivV.count >= 4 ? vivV[vivV.count / 2] : 0.8
        for i in cells.indices where cells[i].kind == .water && !learnedHit.contains(i)
            && feats[i].meanV < min(0.6, typicalV * 0.7) {
            cells[i].kind = .jammer
            cells[i].confidence = 0.85
        }
        // 3. 水がない盤面でも、盤面の色ドロップの典型よりはっきりくすんだ青はお邪魔
        for i in cells.indices where cells[i].kind == .water && !learnedHit.contains(i) && feats[i].meanS < min(0.5, typicalS * 0.8) {
            cells[i].kind = .jammer
            cells[i].confidence = 0.6
        }
        // 盤面全体が暗く色が薄い（実機で、敵の行動中などに盤面が暗くなったとき：明るさ 0.34・鮮やかさ 0.30 前後。
        // 通常は明るさ 0.67〜0.76・鮮やかさ 0.43〜0.59）
        let bv = feats.map { $0.bodyV }.sorted()[feats.count / 2]
        let bsMed = feats.map { $0.bodyS }.sorted()[feats.count / 2]
        let dimmed = bv < 0.45 && bsMed < 0.4
        let taped = tapePoints.keys.sorted()
        return BoardReading(rect: rect, cells: cells, brightness: vSum / Double(max(1, size.count)), dimmed: dimmed ? true : nil,
                            taped: taped.isEmpty ? nil : taped)
    }

    /// 操作不可（テープ）の帯。行（横の帯）または列（縦の帯）に貼られ、そのマスのドロップは動かせない。
    /// from / to は帯の端の位置（そのマスの上端・左端を 0、下端・右端を 1 とする）
    public struct TapeBand: Equatable, Sendable {
        public var vertical: Bool
        public var index: Int
        public var from: Double
        public var to: Double
    }

    /// 画面の帯（実機：濃い茶色の線で上下を縁取られた金色の模様の帯が、盤面の端から端までまっすぐ続く）を探す。
    /// ドロップは丸いので、盤面の幅いっぱいにまっすぐ続く暗い線や金色の線はできない（ドロップの境目でも暗い所は半分ほど）
    public static func tapeBands(_ src: PixelSource, rect: BoardRect) -> [TapeBand] {
        tapeBands(src, rect: rect, vertical: false) + tapeBands(src, rect: rect, vertical: true)
    }

    static func tapeBands(_ src: PixelSource, rect: BoardRect, vertical: Bool) -> [TapeBand] {
        let c = rect.cell
        let length = vertical ? rect.width : rect.height   // 線を順に見ていく方向の長さ
        let span = vertical ? rect.height : rect.width     // 1 本の線の長さ（盤面の端から端まで）
        let count = vertical ? rect.size.cols : rect.size.rows
        func pixel(_ t: Double, _ u: Double) -> (h: Double, s: Double, v: Double) {
            let x = vertical ? rect.x + t : rect.x + u
            let y = vertical ? rect.y + u : rect.y + t
            let p = src.rgb(min(max(Int(x), 0), src.width - 1), min(max(Int(y), 0), src.height - 1))
            return RGB(p.0, p.1, p.2).hsv
        }
        /// その線のうち、暗い画素・帯の金色の画素の割合
        func line(_ t: Int, _ n: Int) -> (dark: Double, tape: Double) {
            var d = 0, g = 0
            for k in 0..<n {
                let u = c * 0.02 + (span - c * 0.04) * (Double(k) + 0.5) / Double(n)
                let (h, s, v) = pixel(Double(t), u)
                if v < 0.35 { d += 1 } else if (25...60).contains(h) && (0.25...0.75).contains(s) && v >= 0.55 { g += 1 }
            }
            return (Double(d) / Double(n), Double(g) / Double(n))
        }
        let t0 = Int(c * 0.08), t1 = Int(length - c * 0.08)
        guard t1 > t0 + 2 else { return [] }
        // 1. 盤面の幅いっぱいに続く暗い線（ドロップを持って帯の上を通っても見つかるように、4分の3以上で十分とする）
        var darkLines: [Int] = []
        for t in t0..<t1 where line(t, 24).dark >= 0.7 && line(t, 60).dark >= 0.75 { darkLines.append(t) }
        var edges: [(Int, Int)] = []
        for t in darkLines {
            if let last = edges.last, t - last.1 <= 2 { edges[edges.count - 1].1 = t } else { edges.append((t, t)) }
        }
        guard edges.count >= 2 else { return [] }
        // 2. となり合う2本の暗い線の間が、帯の太さで、金色の模様が続いていれば帯
        var out: [TapeBand] = []
        for i in 0..<(edges.count - 1) {
            let a = edges[i].1, b = edges[i + 1].0
            let h = Double(b - a) / c
            guard h >= 0.3, h <= 0.8 else { continue }
            // 帯の内側の縁は金色の線
            let ea = (a + 1)...min(a + 3, b - 1), eb = max(b - 3, a + 1)...(b - 1)
            guard ea.map({ line($0, 60).tape }).max() ?? 0 >= 0.6,
                  eb.map({ line($0, 60).tape }).max() ?? 0 >= 0.6 else { continue }
            var sum = 0.0, n = 0
            for t in stride(from: a + 1, to: b, by: 2) { sum += line(t, 40).tape; n += 1 }
            guard n > 0, sum / Double(n) >= 0.35 else { continue }
            let mid = Double(a + b) / 2 / c
            let index = Int(mid)
            guard index >= 0, index < count else { continue }
            out.append(TapeBand(vertical: vertical, index: index,
                                from: Double(a) / c - Double(index), to: Double(b) / c - Double(index)))
        }
        return out
    }

    /// テープの帯に隠れていない所の、ドロップの内側の見る位置（マスの中心からのずれ）
    static func visiblePoints(excluding bands: [TapeBand]) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        var fy = 0.08
        while fy <= 0.92 {
            var fx = 0.12
            while fx <= 0.88 {
                let inside = (fx - 0.5) * (fx - 0.5) + (fy - 0.5) * (fy - 0.5) <= 0.40 * 0.40
                let hidden = bands.contains { b in
                    let p = b.vertical ? fx : fy
                    return p >= b.from - 0.05 && p <= b.to + 0.05
                }
                if inside && !hidden { pts.append((fx - 0.5, fy - 0.5)) }
                fx += 0.06
            }
            fy += 0.035
        }
        return pts
    }

    /// 彩度の低い色のマスをお邪魔と判断するか（紫系＝毒・猛毒は除く）
    static func isDullJammer(_ f: CellFeature, dullLimit: Double) -> Bool {
        guard let h = f.hue, !(255..<300).contains(h) else { return false }
        // 盤面の色ドロップより明らかにくすんでいて、とても色が薄いか、青〜緑がかった灰色（お邪魔によくある色味）ならお邪魔
        guard f.meanS < dullLimit else { return false }
        return f.meanS < 0.36 || (150..<260).contains(h)
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
    /// 盤面候補を探す。
    /// 1. 画面の下 75% を走査し、丸いドロップが規則的に並んでいそうな位置（並びの点数の山）を、大きさ・左右の余白ごとに数か所ずつ集める
    /// 2. 点数の高い候補を実際に読んでみて、ドロップとして一番はっきり読める（信頼度が高い）位置を選ぶ
    ///    （盤面の上にあるチームや敵の表示も「丸いものが並ぶ」ように見えることがあり、並びの点数だけでは数段ずれて選ぶことがある）
    /// - Parameter fixedSize: 手動でサイズを選んだ場合はそのサイズだけを試す
    public static func detect(_ src: PixelSource, fixedSize: BoardSize? = nil,
                              classifier: ColorClassifier = ColorClassifier()) -> BoardReading? {
        let sizes = fixedSize.map { [$0] } ?? BoardSize.supported
        let W = Double(src.width), H = Double(src.height)
        var cands: [(score: Double, rect: BoardRect, metric: Metric)] = []

        for size in sizes {
            for inset in [0.0, 0.01, 0.02, 0.03, 0.045, 0.06, 0.08] {
                let width = W * (1 - inset * 2)
                let cell = width / Double(size.cols)
                let h = cell * Double(size.rows)
                let x = W * inset
                // 画面の下 75% を粗く走査。2つの指標で候補を出す：
                // ・並びの点数（ドロップの間が暗い）
                // ・マスの中の色のそろい具合（ドロップ同士がくっついて見える盤面でも、1マスに1個のドロップがぴったり入る位置で高くなる）
                let step = max(2, cell / 10)
                for metric in [Metric.grid, .uniform] {
                var scan: [(Double, Double)] = []
                var y = H * 0.25
                while y + h <= H {
                    scan.append((score(metric, src, BoardRect(x: x, y: y, cell: cell, size: size)), y))
                    y += step
                }
                // 点数の山（前後より高い所）を高い順に3つまで。近すぎる山は1つにまとめる
                var peaks: [(Double, Double)] = []
                for i in scan.indices {
                    let prev = i > 0 ? scan[i - 1].0 : -Double.infinity
                    let next = i + 1 < scan.count ? scan[i + 1].0 : -Double.infinity
                    if scan[i].0 >= prev && scan[i].0 >= next { peaks.append(scan[i]) }
                }
                peaks.sort { $0.0 > $1.0 }
                var chosen: [(Double, Double)] = []
                for p in peaks where chosen.count < 3 && !chosen.contains(where: { abs($0.1 - p.1) < cell * 0.5 }) {
                    chosen.append(p)
                }
                for (s, y0) in chosen {
                    // 細かく合わせ込む
                    // 同じ点数が続く場合はその真ん中（端に寄らないように）
                    var fine: [(Double, Double)] = [(s, y0)]
                    var yy = max(0, y0 - step)
                    while yy <= min(H - h, y0 + step) {
                        fine.append((score(metric, src, BoardRect(x: x, y: yy, cell: cell, size: size)), yy))
                        yy += 1
                    }
                    let top = fine.map { $0.0 }.max() ?? s
                    let ys = fine.filter { $0.0 >= top - 1e-9 }.map { $0.1 }.sorted()
                    let yBest = ys[ys.count / 2]
                    cands.append((top, BoardRect(x: x, y: yBest, cell: cell, size: size), metric))
                }
                }
            }
        }
        guard !cands.isEmpty else { return nil }
        // 指標ごとに上位の候補を実際に読み、一番はっきり読める位置を選ぶ
        var pool: [BoardRect] = []
        for m in [Metric.grid, .uniform] {
            pool += cands.filter { $0.metric == m }.sorted { $0.score > $1.score }.prefix(8).map { $0.rect }
        }
        var best: (q: Double, reading: BoardReading)?
        for rect in pool where !looksLikeOwnDrawing(src, rect) {
            let rd = BoardReader.read(src, rect: rect, classifier: classifier)
            let q = placementScore(rd, screenHeight: H)
            if best == nil || q > best!.q { best = (q, rd) }
        }
        guard let b = best, b.reading.isUsable else { return nil }
        return b.reading
    }

    enum Metric { case grid, uniform }

    static func score(_ m: Metric, _ src: PixelSource, _ rect: BoardRect) -> Double {
        m == .grid ? gridScore(src, rect) : uniformScore(src, rect)
    }

    /// マスの中の色のそろい具合。各マスの中心から少し離れた8点が、同じ色相の鮮やかな色（または同じ明るさの灰色）なら1マス分。
    /// ずれていると2つのドロップにまたがって色がばらばらになる
    static func uniformScore(_ src: PixelSource, _ rect: BoardRect) -> Double {
        let size = rect.size
        var total = 0.0
        for r in 0..<size.rows {
            for c in 0..<size.cols {
                let cx = rect.x + (Double(c) + 0.5) * rect.cell
                let cy = rect.y + (Double(r) + 0.5) * rect.cell
                var hs: [Double] = [], vs: [Double] = []
                hs.reserveCapacity(8)
                for (dx, dy) in uniformOffsets {
                    let p = src.rgb(clampX(src, cx + dx * rect.cell), clampY(src, cy + dy * rect.cell))
                    let (h, sat, v) = RGB(p.0, p.1, p.2).hsv
                    if sat >= 0.25 && v >= 0.25 { hs.append(h) } else if v >= 0.35 { vs.append(v) }
                }
                if hs.count >= 7 {
                    var sx = 0.0, sy = 0.0
                    for h in hs { sx += cos(h * Double.pi / 180); sy += sin(h * Double.pi / 180) }
                    var m = atan2(sy, sx) * 180 / Double.pi
                    if m < 0 { m += 360 }
                    if hs.allSatisfy({ BoardReader.hueDistance($0, m) <= 25 }) { total += 1 }
                } else if vs.count >= 7, let lo = vs.min(), let hi = vs.max(), hi - lo <= 0.25 {
                    total += 0.6
                }
            }
        }
        return total / Double(size.count)
    }

    static let uniformOffsets: [(Double, Double)] = (0..<8).map {
        let a = Double($0) * Double.pi / 4
        return (0.25 * cos(a), 0.25 * sin(a))
    }

    /// 位置の良さ：はっきり読めること＋盤面は画面の下のほうにあること（実機では下端が画面の 95% 前後）。
    /// 下端が画面の 85% より上にある候補は不利にする（盤面の上の背景やアイコンを盤面と間違えないように）
    public static func placementScore(_ r: BoardReading, screenHeight H: Double) -> Double {
        let bottom = (r.rect.y + r.rect.height) / max(1, H)
        return quality(r) - 1.0 * max(0, 0.9 - bottom)
    }

    /// アプリ自身の小窓（盤面の図）のマスの色。画面共有の映像には小窓も映るので、これを盤面と間違えないようにする
    static let ownTileColors = [RGB(41, 51, 79), RGB(48, 61, 89)]

    /// マスの角（ドロップの外側）の多くが小窓のマスの紺色なら、アプリ自身の図（ゲームの盤面のマスは茶色）
    public static func looksLikeOwnDrawing(_ src: PixelSource, _ rect: BoardRect) -> Bool {
        var hit = 0, n = 0
        for i in 0..<rect.size.count {
            let x0 = rect.x + Double(i % rect.size.cols) * rect.cell
            let y0 = rect.y + Double(i / rect.size.cols) * rect.cell
            for (fx, fy) in [(0.07, 0.07), (0.93, 0.07), (0.07, 0.93), (0.93, 0.93)] {
                let p = src.rgb(clampX(src, x0 + rect.cell * fx), clampY(src, y0 + rect.cell * fy))
                let c = RGB(p.0, p.1, p.2)
                n += 1
                if ownTileColors.contains(where: { $0.distance(to: c) < 30 }) { hit += 1 }
            }
        }
        return hit * 2 >= n
    }

    /// 読み取り結果のはっきりさ（大きいほど、本物の盤面にぴったり合っている）
    public static func quality(_ r: BoardReading) -> Double {
        guard !r.cells.isEmpty else { return 0 }
        let n = Double(r.cells.count)
        let high = Double(r.cells.filter { $0.confidence >= 0.9 }.count) / n
        return r.averageConfidence + 0.15 * high - 0.03 * Double(r.uncertainCount) - 0.6 * max(0, r.whiteFraction - 0.4)
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

/// 画面共有の映像（YCbCr）を RGB に直す。映像ごとの変換式（BT.601 / 709 / 2020）と
/// 値の範囲（フルレンジ／ビデオレンジ）に合わせないと、色相や鮮やかさがずれて色を読み違える。
public struct YCbCrConverter: Equatable, Sendable {
    public enum Matrix: String, Sendable { case bt601, bt709, bt2020 }

    public let matrix: Matrix
    public let fullRange: Bool
    private let rCr: Double, gCb: Double, gCr: Double, bCb: Double

    public init(matrix: Matrix, fullRange: Bool) {
        self.matrix = matrix
        self.fullRange = fullRange
        let (kr, kb): (Double, Double)
        switch matrix {
        case .bt601: (kr, kb) = (0.299, 0.114)
        case .bt709: (kr, kb) = (0.2126, 0.0722)
        case .bt2020: (kr, kb) = (0.2627, 0.0593)
        }
        let kg = 1 - kr - kb
        rCr = 2 * (1 - kr)
        bCb = 2 * (1 - kb)
        gCb = -2 * kb * (1 - kb) / kg
        gCr = -2 * kr * (1 - kr) / kg
    }

    /// 変換式の指定がない映像：HD 以上は BT.709、それより小さければ BT.601（映像の一般的な決まり）
    public static func defaultMatrix(height: Int) -> Matrix { height > 576 ? .bt709 : .bt601 }

    @inline(__always)
    public func rgb(_ y: UInt8, _ cb: UInt8, _ cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let Y: Double, Cb: Double, Cr: Double
        if fullRange {
            Y = Double(y) / 255
            Cb = (Double(cb) - 128) / 255
            Cr = (Double(cr) - 128) / 255
        } else {
            Y = (Double(y) - 16) / 219
            Cb = (Double(cb) - 128) / 224
            Cr = (Double(cr) - 128) / 224
        }
        @inline(__always) func q(_ v: Double) -> UInt8 { UInt8(min(255, max(0, (v * 255).rounded()))) }
        return (q(Y + rCr * Cr), q(Y + gCb * Cb + gCr * Cr), q(Y + bCb * Cb))
    }

    /// テスト用：RGB を YCbCr にする（rgb の逆）
    public func ycbcr(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let R = Double(r) / 255, G = Double(g) / 255, B = Double(b) / 255
        let kr = (1 - rCr / 2), kb = (1 - bCb / 2), kg = 1 - kr - kb
        let Y = kr * R + kg * G + kb * B
        let Cb = (B - Y) / bCb, Cr = (R - Y) / rCr
        @inline(__always) func q(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v.rounded()))) }
        if fullRange { return (q(Y * 255), q(Cb * 255 + 128), q(Cr * 255 + 128)) }
        return (q(16 + Y * 219), q(128 + Cb * 224), q(128 + Cr * 224))
    }
}

/// RGBA の画素の並び（スクリーンショットを端末内で読むとき用。画像は保存しない）
public struct RGBAImageSource: PixelSource {
    public let width: Int, height: Int
    private let bytes: [UInt8]
    private let rowBytes: Int

    public init?(width: Int, height: Int, rowBytes: Int, bytes: [UInt8]) {
        guard width > 0, height > 0, rowBytes >= width * 4, bytes.count >= rowBytes * height else { return nil }
        self.width = width; self.height = height; self.rowBytes = rowBytes; self.bytes = bytes
    }

    public func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        let i = y * rowBytes + x * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2])
    }
}

/// 認識結果の診断情報（文章）。画像は含めず、盤面の位置と各マスの判定・信頼度・代表色だけ
public enum RecognitionDiagnostics {
    public static func text(_ r: BoardReading, source: String, imageSize: (Int, Int)?) -> String {
        var lines: [String] = []
        lines.append("パズルルート 診断情報（画像は含みません）")
        lines.append("入力: \(source)" + (imageSize.map { " \($0.0)x\($0.1)" } ?? ""))
        lines.append(String(format: "盤面: %dx%d 位置 x=%.0f y=%.0f マス=%.1f 明るさ=%.2f 平均信頼度=%.2f",
                            r.size.cols, r.size.rows, r.rect.x, r.rect.y, r.rect.cell, r.brightness, r.averageConfidence))
        for row in 0..<r.size.rows {
            var cells: [String] = []
            for col in 0..<r.size.cols {
                let c = r.cells[row * r.size.cols + col]
                let (h, s, v) = c.color.hsv
                cells.append(String(format: "%@ %.2f #%02X%02X%02X h%.0f s%.2f v%.2f",
                                    c.cloud == true ? "cloud" : c.kind.key, c.confidence, c.color.r, c.color.g, c.color.b, h, s, v))
            }
            lines.append("\(row + 1)段目: " + cells.joined(separator: " | "))
        }
        if let t = r.taped, !t.isEmpty {
            lines.append("操作不可（テープ）を自動で見つけたマス: "
                         + t.map { "\($0 / r.size.cols + 1)段\($0 % r.size.cols + 1)列" }.joined(separator: " "))
        } else {
            lines.append("操作不可（テープ）を自動で見つけたマス: なし（この画面）")
        }
        return lines.joined(separator: "\n")
    }
}

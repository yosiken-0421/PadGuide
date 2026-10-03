import Foundation

// MARK: - 共通定義（アプリ本体とブロードキャスト拡張の両方で使う）

enum Orb {
    static let fire: Int8 = 0, water: Int8 = 1, wood: Int8 = 2, light: Int8 = 3, dark: Int8 = 4, heart: Int8 = 5
    static let other: Int8 = 6
    static let empty: Int8 = -1
    static let rows = 5, cols = 6, cells = 30
    static let labels = ["火", "水", "木", "光", "闇", "回", "?"]
}

enum Shared {
    /** App Group ID は Info.plist（project.yml の PD_APP_GROUP）から読む */
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "PDAppGroup") as? String ?? "group.com.pdguide"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
    }
    static var resultURL: URL { container.appendingPathComponent("result.json") }
    static var previewURL: URL { container.appendingPathComponent("preview.jpg") }

    // 盤面位置（画面に対する割合）。高さ = 幅 × 5/6
    static var boardLeft: Double { get { defaults.object(forKey: "bl") as? Double ?? 0 } set { defaults.set(newValue, forKey: "bl") } }
    static var boardTop: Double { get { defaults.object(forKey: "bt") as? Double ?? 0.52 } set { defaults.set(newValue, forKey: "bt") } }
    static var boardWidth: Double { get { defaults.object(forKey: "bw") as? Double ?? 1 } set { defaults.set(newValue, forKey: "bw") } }
    static var calibrated: Bool { get { defaults.bool(forKey: "cal") } set { defaults.set(newValue, forKey: "cal") } }
    static var requestAutoDetect: Bool { get { defaults.bool(forKey: "autodet") } set { defaults.set(newValue, forKey: "autodet") } }
    static var wantPreview: Bool { get { defaults.bool(forKey: "wantprev") } set { defaults.set(newValue, forKey: "wantprev") } }

    static var maxSteps: Int { get { defaults.object(forKey: "steps") as? Int ?? 20 } set { defaults.set(newValue, forKey: "steps") } }
    static var diagonal: Bool { get { defaults.bool(forKey: "diag") } set { defaults.set(newValue, forKey: "diag") } }
    static var beamWidth: Int { get { defaults.object(forKey: "beam") as? Int ?? 800 } set { defaults.set(newValue, forKey: "beam") } }
}

/** 拡張 → アプリ本体へ渡す解析結果 */
struct GuideResult: Codable {
    var status: String          // "ok" | "invalid" | "nocombo"
    var board: [Int8]
    var path: [Int]
    var combos: Int
    var maxCombos: Int
    var timestamp: Double
}

struct BoardRect {
    var x: Double, y: Double, w: Double
    var h: Double { w * Double(Orb.rows) / Double(Orb.cols) }
    var cell: Double { w / Double(Orb.cols) }
}

// MARK: - 画素の読み出し

protocol PixelSource {
    var width: Int { get }
    var height: Int { get }
    /** 0〜255 の RGB */
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int)
}

// MARK: - 盤面読み取り

enum BoardReader {
    struct Reading { var board: [Int8]; var confidence: Double
        var unknownCount: Int { board.filter { $0 == Orb.other }.count }
        var looksValid: Bool { confidence >= 0.55 && unknownCount <= 8 }
    }

    // マス中心は矢印で隠れることがあるので斜め4点で多数決
    static let samplePoints: [(Double, Double)] = [(0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7)]

    static func read(_ src: PixelSource, _ r: BoardRect) -> Reading {
        var board = [Int8](repeating: Orb.other, count: Orb.cells)
        let radius = max(1, Int(r.cell * 0.05))
        var agree = 0.0
        for row in 0..<Orb.rows { for col in 0..<Orb.cols {
            var votes = [Int](repeating: 0, count: 7)
            for p in samplePoints {
                let x = Int(r.x + (Double(col) + p.0) * r.cell)
                let y = Int(r.y + (Double(row) + p.1) * r.cell)
                let c = average(src, x, y, radius)
                votes[Int(classify(c.0, c.1, c.2))] += 1
            }
            var best = -1
            for k in 0...5 where votes[k] > 0 && (best < 0 || votes[k] > votes[best]) { best = k }
            board[row * Orb.cols + col] = best >= 0 ? Int8(best) : Orb.other
            agree += Double(best >= 0 ? votes[best] : votes[6]) / 4
        }}
        return Reading(board: board, confidence: agree / Double(Orb.cells))
    }

    /** 幅=画面幅いっぱいと仮定して上下位置を探す */
    static func autoDetect(_ src: PixelSource) -> BoardRect? {
        let w = Double(src.width)
        let cell = w / Double(Orb.cols)
        let h = cell * Double(Orb.rows)
        var bestY = -1.0, bestScore = -1e9
        var y = Double(src.height) * 0.3
        let step = max(2.0, cell / 40)
        while y + h <= Double(src.height) {
            let s = orbScore(src, y, cell)
            if s > bestScore { bestScore = s; bestY = y }
            y += step
        }
        guard bestY >= 0 else { return nil }
        let rect = BoardRect(x: 0, y: bestY, w: w)
        return read(src, rect).looksValid ? rect : nil
    }

    private static func orbScore(_ src: PixelSource, _ top: Double, _ cell: Double) -> Double {
        var s = 0.0
        for r in 0..<Orb.rows { for c in 0..<Orb.cols {
            let x0 = Double(c) * cell, y0 = top + Double(r) * cell
            let a = hsv(src.rgb(Int(x0 + cell * 0.3), Int(y0 + cell * 0.3)))
            let b = hsv(src.rgb(Int(x0 + cell * 0.7), Int(y0 + cell * 0.7)))
            let k = hsv(src.rgb(Int(x0 + cell * 0.04), Int(y0 + cell * 0.04)))
            s += a.1 * a.2 + b.1 * b.2 - k.2 * 0.8
        }}
        return s
    }

    private static func average(_ src: PixelSource, _ cx: Int, _ cy: Int, _ r: Int) -> (Int, Int, Int) {
        var rs = 0, gs = 0, bs = 0, n = 0
        let st = max(1, r / 3)
        var y = cy - r
        while y <= cy + r {
            var x = cx - r
            while x <= cx + r {
                let p = src.rgb(min(max(x, 0), src.width - 1), min(max(y, 0), src.height - 1))
                rs += p.0; gs += p.1; bs += p.2; n += 1
                x += st
            }
            y += st
        }
        return (rs / n, gs / n, bs / n)
    }

    static func hsv(_ c: (Int, Int, Int)) -> (Double, Double, Double) {
        let r = Double(c.0) / 255, g = Double(c.1) / 255, b = Double(c.2) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func classify(_ r: Int, _ g: Int, _ b: Int) -> Int8 {
        let (h, s, v) = hsv((r, g, b))
        if s < 0.28 || v < 0.25 { return Orb.other }
        switch h {
        case 345..., ..<30: return Orb.fire
        case ..<72: return Orb.light
        case ..<165: return Orb.wood
        case ..<250: return Orb.water
        case ..<300: return Orb.dark
        default: return Orb.heart
        }
    }
}

// MARK: - ソルバー（ビームサーチ、Android版と同じアルゴリズム）

final class Solver {
    struct Result { var path: [Int]; var combos: Int; var cleared: Int; var maxCombos: Int }

    private final class Node {
        let board: [Int8], pos: Int, prev: Int, parent: Node?, depth: Int, combos: Int, cleared: Int, score: Int
        init(_ board: [Int8], _ pos: Int, _ prev: Int, _ parent: Node?, _ depth: Int, _ combos: Int, _ cleared: Int, _ score: Int) {
            self.board = board; self.pos = pos; self.prev = prev; self.parent = parent
            self.depth = depth; self.combos = combos; self.cleared = cleared; self.score = score
        }
    }

    let maxSteps: Int, beamWidth: Int
    let dirs: [(Int, Int)]

    init(maxSteps: Int, diagonal: Bool, beamWidth: Int) {
        self.maxSteps = maxSteps; self.beamWidth = beamWidth
        var d = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        if diagonal { d += [(-1, -1), (-1, 1), (1, -1), (1, 1)] }
        dirs = d
    }

    static func theoreticalMax(_ b: [Int8]) -> Int {
        var cnt = [Int](repeating: 0, count: 6)
        for v in b where v >= 0 && v <= 5 { cnt[Int(v)] += 1 }
        return cnt.reduce(0) { $0 + $1 / 3 }
    }

    func solve(_ board: [Int8]) -> Result {
        let mx = Solver.theoreticalMax(board)
        let ev0 = Solver.evaluate(board)
        var beam = (0..<Orb.cells).map { Node(board, $0, -1, nil, 0, ev0.0, ev0.1, score(board, ev0, 0)) }
        var best: Node?
        if maxSteps >= 1 {
            for depth in 1...maxSteps {
                var children: [Node] = []
                children.reserveCapacity(beam.count * dirs.count)
                var seen = Set<[Int8]>()
                for n in beam {
                    let r = n.pos / Orb.cols, c = n.pos % Orb.cols
                    for d in dirs {
                        let nr = r + d.0, nc = c + d.1
                        guard nr >= 0, nr < Orb.rows, nc >= 0, nc < Orb.cols else { continue }
                        let np = nr * Orb.cols + nc
                        if np == n.prev { continue }
                        var b = n.board
                        b.swapAt(n.pos, np)
                        var key = b; key.append(Int8(np))
                        if !seen.insert(key).inserted { continue }
                        let ev = Solver.evaluate(b)
                        let child = Node(b, np, n.pos, n, depth, ev.0, ev.1, score(b, ev, depth))
                        children.append(child)
                        if best == nil || better(child, best!) { best = child }
                    }
                }
                if children.isEmpty { break }
                children.sort { $0.score > $1.score }
                beam = Array(children.prefix(beamWidth))
                if let b = best, b.combos >= mx { break }
            }
        }
        guard let b = best else { return Result(path: [0], combos: ev0.0, cleared: ev0.1, maxCombos: mx) }
        var path: [Int] = []
        var cur: Node? = b
        while let n = cur { path.append(n.pos); cur = n.parent }
        return Result(path: path.reversed(), combos: b.combos, cleared: b.cleared, maxCombos: mx)
    }

    private func better(_ a: Node, _ b: Node) -> Bool {
        if a.combos != b.combos { return a.combos > b.combos }
        if a.depth != b.depth { return a.depth < b.depth }
        return a.cleared > b.cleared
    }

    private func score(_ b: [Int8], _ ev: (Int, Int), _ depth: Int) -> Int {
        var pairs = 0
        for r in 0..<Orb.rows { for c in 0..<Orb.cols {
            let v = b[r * Orb.cols + c]
            if v < 0 || v >= Orb.other { continue }
            if c + 1 < Orb.cols && b[r * Orb.cols + c + 1] == v { pairs += 1 }
            if r + 1 < Orb.rows && b[(r + 1) * Orb.cols + c] == v { pairs += 1 }
        }}
        return ev.0 * 1000 + ev.1 * 10 + pairs * 4 - depth
    }

    /** (コンボ数, 消したドロップ数)。落ちコンなし、既存ドロップによる連鎖はあり */
    static func evaluate(_ src: [Int8]) -> (Int, Int) {
        var g = src
        var combos = 0, cleared = 0
        let C = Orb.cols, R = Orb.rows
        while true {
            var mark = [Bool](repeating: false, count: Orb.cells)
            var any = false
            for r in 0..<R { for c in 0...(C - 3) {
                let i = r * C + c, v = g[i]
                if v >= 0 && v <= 5 && g[i + 1] == v && g[i + 2] == v { mark[i] = true; mark[i + 1] = true; mark[i + 2] = true; any = true }
            }}
            for r in 0...(R - 3) { for c in 0..<C {
                let i = r * C + c, v = g[i]
                if v >= 0 && v <= 5 && g[i + C] == v && g[i + 2 * C] == v { mark[i] = true; mark[i + C] = true; mark[i + 2 * C] = true; any = true }
            }}
            if !any { break }
            var visited = [Bool](repeating: false, count: Orb.cells)
            for i in 0..<Orb.cells where mark[i] && !visited[i] {
                let color = g[i]
                combos += 1
                var stack = [i]; visited[i] = true
                while let p = stack.popLast() {
                    cleared += 1
                    let pr = p / C, pc = p % C
                    var nb: [Int] = []
                    if pr > 0 { nb.append(p - C) }
                    if pr < R - 1 { nb.append(p + C) }
                    if pc > 0 { nb.append(p - 1) }
                    if pc < C - 1 { nb.append(p + 1) }
                    for q in nb where mark[q] && !visited[q] && g[q] == color { visited[q] = true; stack.append(q) }
                }
            }
            for i in 0..<Orb.cells where mark[i] { g[i] = Orb.empty }
            for c in 0..<C {
                var w = R - 1
                for r in stride(from: R - 1, through: 0, by: -1) {
                    let v = g[r * C + c]
                    if v != Orb.empty { g[w * C + c] = v; w -= 1 }
                }
                while w >= 0 { g[w * C + c] = Orb.empty; w -= 1 }
            }
        }
        return (combos, cleared)
    }
}

import Foundation

/// 探索で優先する条件
public struct Goals: Codable, Equatable, Sendable {
    /// この色を多く消す（nil なら指定なし）
    public var priorityColor: OrbKind?
    public var heal: Bool
    public var fiveColors: Bool
    public var lShape: Bool
    public var cross: Bool
    public var row: Bool
    public var square: Bool

    public init(priorityColor: OrbKind? = nil, heal: Bool = false, fiveColors: Bool = false,
                lShape: Bool = false, cross: Bool = false, row: Bool = false, square: Bool = false) {
        self.priorityColor = priorityColor
        self.heal = heal
        self.fiveColors = fiveColors
        self.lShape = lShape
        self.cross = cross
        self.row = row
        self.square = square
    }

    var shapeGoals: [ClearShape] {
        var s: [ClearShape] = []
        if lShape { s.append(.lShape) }
        if cross { s.append(.cross) }
        if row { s.append(.row) }
        if square { s.append(.square) }
        return s
    }
}

public struct SolverOptions: Codable, Equatable, Sendable {
    /// 手数の上限の選択肢。最大コンボには平均で25〜30手ほど必要なので、上限は長めにしている
    public static let stepChoices = [32, 48, 64]
    public static let defaultSteps = 48
    public static let timeChoices: [Double] = [1, 3, 6]

    public var maxSteps: Int
    /// 秒。nil なら時間制限なし（テスト用。結果が毎回同じになる）
    public var timeLimit: Double?
    /// 最初の探索幅。時間制限があり、最大コンボに届かなければ残り時間に合わせて幅を広げて探し直す
    public var beamWidth: Int
    /// 広げるときの上限（画面共有拡張のメモリ上限 50MB に収めるため）
    public var maxBeamWidth: Int
    public var goals: Goals

    public init(maxSteps: Int = SolverOptions.defaultSteps, timeLimit: Double? = 1, beamWidth: Int = 800,
                maxBeamWidth: Int = 12_000, goals: Goals = Goals()) {
        self.maxSteps = maxSteps
        self.timeLimit = timeLimit
        self.beamWidth = beamWidth
        self.maxBeamWidth = maxBeamWidth
        self.goals = goals
    }
}

/// 見つかったルート（最大を保証するものではない「候補」）
public struct Route: Sendable {
    public let size: BoardSize
    public let start: Int
    /// 通過するマス（先頭が開始位置）
    public let path: [Int]
    public let moves: [Direction]
    public let result: EvalResult
    public let score: Int
    public let turns: Int
    public let elapsed: Double
    /// 時間切れ・キャンセルで途中終了したか
    public let stoppedEarly: Bool
    public let cancelled: Bool
    public let expanded: Int

    public var steps: Int { moves.count }
    public var end: Int { path.last ?? start }

    /// 達成した条件（表示用の日本語）
    public func achieved(_ goals: Goals) -> [String] {
        var a: [String] = []
        if result.fiveColors { a.append("5色同時消し") }
        for s in ClearShape.allCases where result.shapes.contains(s) { a.append(s.rawValue) }
        if result.healCleared > 0 { a.append("回復\(result.healCleared)個") }
        if let pc = goals.priorityColor, result.clearedByKind[Int(pc.rawValue)] > 0 {
            a.append("\(pc.label)\(result.clearedByKind[Int(pc.rawValue)])個")
        }
        return a
    }
}

/// 探索の中断用フラグ（別スレッドから cancel() できる）
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// ビームサーチによるルート探索。
/// - 盤面の色の数から決まる最大コンボ数（theoreticalMaxCombos）に届くまで探す
///   （時間内に届かなければ探索幅を広げて探し直し、見つかった中で最も良いものを返す）
/// - 上下左右のみ（斜めなし）、直前マスへ戻る往復は除外
/// - 同じ「盤面＋指の位置」は重複排除
/// - 時間制限・最大手数・キャンセルに対応
/// - 同じ評価なら手数が短い→曲がる回数が少ない順
public enum Solver {

    /// 色ごとの個数から決まるコンボ数の上限（同じ色3個で1コンボ。不明マスは数えない）
    public static func theoreticalMaxCombos(_ board: Board) -> Int {
        theoreticalMaxCombos(board.cells)
    }

    public static func theoreticalMaxCombos(_ cells: [OrbKind]) -> Int {
        var cnt = [Int](repeating: 0, count: OrbKind.allCases.count)
        for k in cells where k.isMatchable { cnt[Int(k.rawValue)] += 1 }
        return cnt.reduce(0) { $0 + $1 / 3 }
    }

    /// 評価値（大きいほど良い）
    public static func goalScore(_ r: EvalResult, _ goals: Goals) -> Int {
        var s = r.combos * 10_000 + r.cleared * 10
        if let pc = goals.priorityColor {
            let i = Int(pc.rawValue)
            s += r.clearedByKind[i] * 400 + (r.combosByKind[i] > 0 ? 3_000 : 0)
        }
        if goals.heal { s += (r.healCleared > 0 ? 3_000 : 0) + r.healCleared * 100 }
        if goals.fiveColors && r.fiveColors { s += 30_000 }
        for shape in goals.shapeGoals where r.shapes.contains(shape) { s += 30_000 }
        return s
    }

    static func allGoalsMet(_ r: EvalResult, _ goals: Goals, maxCombos: Int) -> Bool {
        guard r.combos >= maxCombos else { return false }
        if goals.fiveColors && !r.fiveColors { return false }
        for shape in goals.shapeGoals where !r.shapes.contains(shape) { return false }
        if goals.heal && r.healCleared == 0 { return false }
        if let pc = goals.priorityColor, r.combosByKind[Int(pc.rawValue)] == 0 { return false }
        return true
    }

    /// goalScore と同じ計算を、Evaluator の直前の結果から行う（メモリ確保なし）
    static func quickScore(_ e: Evaluator, _ goals: Goals, _ shapeBits: UInt8) -> Int {
        var s = e.qCombos * 10_000 + e.qCleared * 10
        if let pc = goals.priorityColor {
            let i = Int(pc.rawValue)
            s += e.qClearedByKind[i] * 400 + (e.qCombosByKind[i] > 0 ? 3_000 : 0)
        }
        let heart = Int(OrbKind.heart.rawValue)
        if goals.heal { s += (e.qClearedByKind[heart] > 0 ? 3_000 : 0) + e.qClearedByKind[heart] * 100 }
        if goals.fiveColors && quickFiveColors(e) { s += 30_000 }
        s += (e.qShapes & shapeBits).nonzeroBitCount * 30_000
        return s
    }

    static func quickFiveColors(_ e: Evaluator) -> Bool {
        for k in 0...4 where e.qCombosByKind[k] == 0 { return false }
        return true
    }

    static func quickGoalsMet(_ e: Evaluator, _ goals: Goals, _ shapeBits: UInt8, maxCombos: Int) -> Bool {
        guard e.qCombos >= maxCombos else { return false }
        if goals.fiveColors && !quickFiveColors(e) { return false }
        if e.qShapes & shapeBits != shapeBits { return false }
        if goals.heal && e.qClearedByKind[Int(OrbKind.heart.rawValue)] == 0 { return false }
        if let pc = goals.priorityColor, e.qCombosByKind[Int(pc.rawValue)] == 0 { return false }
        return true
    }

    /// 最大コンボに向けた盤面の「揃いやすさ」。
    /// - 隣り合う同じ色（ペア）と、1マス空けて並ぶ同じ色を加点
    /// - 4個以上つなげて消すと、その色で作れるコンボが減るので減点
    static func potential(_ b: UnsafePointer<Int8>, _ size: BoardSize, _ e: Evaluator) -> Int {
        let C = size.cols, R = size.rows
        let unknown = OrbKind.unknown.rawValue
        var pairs = 0, near = 0
        for r in 0..<R {
            for c in 0..<C {
                let i = r * C + c
                let v = b[i]
                if v < 0 || v == unknown { continue }
                if c + 1 < C && b[i + 1] == v { pairs += 1 }
                if r + 1 < R && b[i + C] == v { pairs += 1 }
                if c + 2 < C && b[i + 2] == v && b[i + 1] != v { near += 1 }
                if r + 2 < R && b[i + 2 * C] == v && b[i + C] != v { near += 1 }
            }
        }
        var waste = 0
        for k in 0..<Evaluator.kindCount where e.qCombosByKind[k] > 0 {
            waste += e.qClearedByKind[k] - 3 * e.qCombosByKind[k]
        }
        return pairs * 30 + near * 15 - waste * 100
    }

    /// 1回分のビームサーチの結果
    struct RunResult {
        var path: [Int] = []
        var score = Int.min
        var steps = 0
        var turns = 0
        var met = false
        var stopped = false
        var cancelled = false
        var expanded = 0

        func isBetter(than o: RunResult) -> Bool {
            if score != o.score { return score > o.score }
            if steps != o.steps { return steps < o.steps }
            return turns < o.turns
        }
    }

    public static func solve(_ board: Board,
                             options: SolverOptions,
                             cancel: CancellationFlag? = nil,
                             clock: () -> Double = { Date().timeIntervalSinceReferenceDate }) -> Route {
        let size = board.size
        let C = size.cols
        let t0 = clock()
        let deadline = options.timeLimit.map { t0 + $0 }
        let evaluator = Evaluator(size: size)
        let goals = options.goals
        let maxCombos = theoreticalMaxCombos(board)
        let maxSteps = max(1, options.maxSteps)
        let base = board.raw

        // 何も動かさない状態
        let ev0 = evaluator.evaluate(raw: base)
        var best = RunResult()
        best.path = [0]
        best.score = goalScore(ev0, goals)
        best.met = allGoalsMet(ev0, goals, maxCombos: maxCombos)

        var width = max(1, options.beamWidth)
        var stopped = false, cancelled = false, expanded = 0
        while true {
            let runStart = clock()
            let r = beamRun(base: base, size: size, width: width, maxSteps: maxSteps, goals: goals,
                            maxCombos: maxCombos, evaluator: evaluator, deadline: deadline, cancel: cancel, clock: clock)
            expanded += r.expanded
            if r.path.count >= 2 && r.isBetter(than: best) { best = r }
            if r.cancelled { cancelled = true; stopped = true; break }
            if r.stopped { stopped = true; break }
            if best.met { break }
            // 最大コンボに届かなかった：残り時間で探索幅を広げて探し直す
            guard let dl = deadline else { break }
            let now = clock()
            let rate = Double(r.expanded) / max(now - runStart, 1e-4)
            let remaining = dl - now
            guard remaining > 0 else { stopped = true; break }
            let next = Int(min(rate * remaining * 0.85 / (2.6 * Double(maxSteps)), Double(options.maxBeamWidth)))
            guard next >= width * 13 / 10 else { break }
            width = next
        }

        // 最良ルートの盤面を、形の判定も含めて評価し直す
        let path = best.path
        var cells = base
        if path.count >= 2 { for k in 1..<path.count { cells.swapAt(path[k - 1], path[k]) } }
        let result = path.count >= 2 ? evaluator.evaluate(raw: cells) : ev0
        var moves: [Direction] = []
        if path.count >= 2 {
            for k in 1..<path.count {
                let a = path[k - 1], b = path[k]
                let dr = b / C - a / C, dc = b % C - a % C
                let m: Direction = dr == -1 ? .up : dr == 1 ? .down : dc == -1 ? .left : .right
                moves.append(m)
            }
        }
        return Route(size: size, start: path[0], path: path, moves: moves, result: result,
                     score: goalScore(result, goals), turns: best.turns, elapsed: clock() - t0,
                     stoppedEarly: stopped, cancelled: cancelled, expanded: expanded)
    }

    /// 探索幅 width のビームサーチを1回行う
    static func beamRun(base: [Int8], size: BoardSize, width: Int, maxSteps: Int, goals: Goals, maxCombos: Int,
                        evaluator: Evaluator, deadline: Double?, cancel: CancellationFlag?,
                        clock: () -> Double) -> RunResult {
        let N = size.count
        let dirs = Direction.allCases
        let wantShapes = !goals.shapeGoals.isEmpty
        var shapeBits: UInt8 = 0
        for (i, s) in ClearShape.allCases.enumerated() where goals.shapeGoals.contains(s) { shapeBits |= 1 << UInt8(i) }
        // 隣のマス（盤面外は -1）
        var nbr = [Int](repeating: -1, count: N * 4)
        for p in 0..<N { for (di, d) in dirs.enumerated() { nbr[p * 4 + di] = BoardOps.neighbor(p, d, size) ?? -1 } }

        let beamCap = max(width, N)
        let candCap = beamCap * 4
        let beamBoards = UnsafeMutablePointer<Int8>.allocate(capacity: beamCap * N)
        let candBoards = UnsafeMutablePointer<Int8>.allocate(capacity: candCap * N)
        defer { beamBoards.deallocate(); candBoards.deallocate() }

        var beamPos = [Int](), beamPrev = [Int](), beamDir = [Int](), beamTurns = [Int]()
        beamPos.reserveCapacity(beamCap); beamPrev.reserveCapacity(beamCap)
        beamDir.reserveCapacity(beamCap); beamTurns.reserveCapacity(beamCap)
        for p in 0..<N {
            for k in 0..<N { beamBoards[p * N + k] = base[k] }
            beamPos.append(p); beamPrev.append(-1); beamDir.append(-1); beamTurns.append(0)
        }
        // 経路復元用：深さごとの (親の index, 位置)
        var layerParent: [[Int32]] = [[Int32](repeating: -1, count: N)]
        var layerPos: [[UInt8]] = [(0..<N).map { UInt8($0) }]

        var res = RunResult()
        var bestDepth = -1, bestParent = -1, bestLast = 0

        var candParent = [Int](), candPos = [Int](), candDir = [Int](), candTurns = [Int](), candHeur = [Int]()
        candParent.reserveCapacity(candCap); candPos.reserveCapacity(candCap); candDir.reserveCapacity(candCap)
        candTurns.reserveCapacity(candCap); candHeur.reserveCapacity(candCap)
        var seen = Set<UInt64>(minimumCapacity: candCap)
        var order = [Int](); order.reserveCapacity(candCap)

        depthLoop: for depth in 1...maxSteps {
            let beamCount = beamPos.count
            candParent.removeAll(keepingCapacity: true); candPos.removeAll(keepingCapacity: true)
            candDir.removeAll(keepingCapacity: true); candTurns.removeAll(keepingCapacity: true)
            candHeur.removeAll(keepingCapacity: true)
            seen.removeAll(keepingCapacity: true)

            for i in 0..<beamCount {
                let pos = beamPos[i]
                let src = beamBoards + i * N
                for di in 0..<4 {
                    let np = nbr[pos * 4 + di]
                    if np < 0 || np == beamPrev[i] { continue }   // 盤面外・往復は除外
                    let ci = candPos.count
                    let w = candBoards + ci * N
                    w.update(from: src, count: N)
                    let t = w[pos]; w[pos] = w[np]; w[np] = t

                    // 重複排除用のハッシュ（FNV-1a、実行ごとに同じ値）
                    var h: UInt64 = 0xcbf29ce484222325
                    for k in 0..<N { h = (h ^ UInt64(UInt8(bitPattern: w[k]))) &* 0x100000001b3 }
                    h = (h ^ UInt64(np)) &* 0x100000001b3
                    if !seen.insert(h).inserted { continue }

                    res.expanded += 1
                    evaluator.run(UnsafePointer(w), shapes: wantShapes)
                    let score = quickScore(evaluator, goals, shapeBits)
                    let turns = beamTurns[i] + ((beamDir[i] >= 0 && beamDir[i] != di) ? 1 : 0)
                    let heur = score - evaluator.qCleared * 10 + potential(UnsafePointer(w), size, evaluator) - turns

                    candParent.append(i); candPos.append(np); candDir.append(di)
                    candTurns.append(turns); candHeur.append(heur)

                    if score > res.score || (score == res.score && (depth < res.steps || (depth == res.steps && turns < res.turns))) {
                        bestDepth = depth - 1; bestParent = i; bestLast = np
                        res.score = score; res.steps = depth; res.turns = turns
                        res.met = quickGoalsMet(evaluator, goals, shapeBits, maxCombos: maxCombos)
                    }

                    if res.expanded & 255 == 0 {
                        if cancel?.isCancelled == true { res.cancelled = true; res.stopped = true; break depthLoop }
                        if let dl = deadline, clock() > dl { res.stopped = true; break depthLoop }
                    }
                }
            }
            if candPos.isEmpty || res.met { break }

            // 上位 width 件を残す（同点は生成順で決めるので結果は毎回同じ）
            order.removeAll(keepingCapacity: true)
            order.append(contentsOf: 0..<candPos.count)
            order.sort { a, b in candHeur[a] != candHeur[b] ? candHeur[a] > candHeur[b] : a < b }
            let keep = min(width, order.count)

            var np = [Int](), npr = [Int](), nd = [Int](), nt = [Int]()
            np.reserveCapacity(keep); npr.reserveCapacity(keep); nd.reserveCapacity(keep); nt.reserveCapacity(keep)
            var lp = [Int32](), lpos = [UInt8]()
            lp.reserveCapacity(keep); lpos.reserveCapacity(keep)
            for j in 0..<keep {
                let idx = order[j]
                (beamBoards + j * N).update(from: candBoards + idx * N, count: N)
                np.append(candPos[idx])
                npr.append(beamPos[candParent[idx]])
                nd.append(candDir[idx])
                nt.append(candTurns[idx])
                lp.append(Int32(candParent[idx]))
                lpos.append(UInt8(candPos[idx]))
            }
            beamPos = np; beamPrev = npr; beamDir = nd; beamTurns = nt
            layerParent.append(lp)
            layerPos.append(lpos)

            if cancel?.isCancelled == true { res.cancelled = true; res.stopped = true; break }
            if let dl = deadline, clock() > dl { res.stopped = true; break }
        }

        // 経路を復元
        if bestDepth >= 0 {
            var path = [bestLast]
            var d = bestDepth, i = bestParent
            while d >= 0 && i >= 0 {
                path.append(Int(layerPos[d][i]))
                i = Int(layerParent[d][i])
                d -= 1
            }
            res.path = path.reversed()
        }
        return res
    }
}

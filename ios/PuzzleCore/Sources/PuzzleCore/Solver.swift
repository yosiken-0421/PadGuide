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
    public static let stepChoices = [20, 32, 48]
    public static let timeChoices: [Double] = [1, 3, 6]

    public var maxSteps: Int
    /// 秒。nil なら時間制限なし（テスト用。結果が毎回同じになる）
    public var timeLimit: Double?
    public var beamWidth: Int
    public var goals: Goals

    public init(maxSteps: Int = 20, timeLimit: Double? = 1, beamWidth: Int = 1200, goals: Goals = Goals()) {
        self.maxSteps = maxSteps
        self.timeLimit = timeLimit
        self.beamWidth = beamWidth
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
/// - 上下左右のみ（斜めなし）、直前マスへ戻る往復は除外
/// - 同じ「盤面＋指の位置」は重複排除
/// - 時間制限・最大手数・キャンセルに対応
/// - 同じ評価なら手数が短い→曲がる回数が少ない順
public enum Solver {

    public static func theoreticalMaxCombos(_ board: Board) -> Int {
        var cnt = [Int](repeating: 0, count: OrbKind.allCases.count)
        for k in board.cells where k.isMatchable { cnt[Int(k.rawValue)] += 1 }
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

    private static func pairs(_ b: UnsafeBufferPointer<Int8>, _ size: BoardSize) -> Int {
        let C = size.cols, R = size.rows
        let unknown = OrbKind.unknown.rawValue
        var p = 0
        for r in 0..<R {
            for c in 0..<C {
                let v = b[r * C + c]
                if v < 0 || v == unknown { continue }
                if c + 1 < C && b[r * C + c + 1] == v { p += 1 }
                if r + 1 < R && b[(r + 1) * C + c] == v { p += 1 }
            }
        }
        return p
    }

    public static func solve(_ board: Board,
                             options: SolverOptions,
                             cancel: CancellationFlag? = nil,
                             clock: () -> Double = { Date().timeIntervalSinceReferenceDate }) -> Route {
        let size = board.size
        let N = size.count
        let C = size.cols
        let t0 = clock()
        let deadline = options.timeLimit.map { t0 + $0 }
        let evaluator = Evaluator(size: size)
        let goals = options.goals
        let maxCombos = theoreticalMaxCombos(board)
        let dirs = Direction.allCases
        let beamWidth = max(1, options.beamWidth)

        // 何も動かさない状態
        let base = board.raw
        let ev0 = evaluator.evaluate(raw: base)

        // 現在のビーム（盤面はフラットな配列に詰める）
        var beamBoards = [Int8]()
        beamBoards.reserveCapacity(N * N)
        var beamPos = [Int]()
        var beamPrev = [Int]()
        var beamDir = [Int]()      // 直前の方向（-1 = なし）
        var beamTurns = [Int]()
        // 経路復元用：深さごとの (親の index, 位置)
        var layerParent: [[Int32]] = []
        var layerPos: [[UInt8]] = []

        for p in 0..<N {
            beamBoards.append(contentsOf: base)
            beamPos.append(p)
            beamPrev.append(-1)
            beamDir.append(-1)
            beamTurns.append(0)
        }
        layerParent.append([Int32](repeating: -1, count: N))
        layerPos.append((0..<N).map { UInt8($0) })

        // 最良候補：(親の深さ, 親の index, 最後の位置, 評価, スコア, 手数, 曲がり数)
        var bestDepth = -1, bestParent = -1, bestLast = 0
        var bestRes = ev0, bestScore = goalScore(ev0, goals), bestSteps = 0, bestTurns = 0
        var stopped = false, cancelled = false
        var expanded = 0

        func isBetter(score: Int, steps: Int, turns: Int) -> Bool {
            if score != bestScore { return score > bestScore }
            if steps != bestSteps { return steps < bestSteps }
            return turns < bestTurns
        }

        var candBoards = [Int8]()
        var candParent = [Int]()
        var candPos = [Int]()
        var candDir = [Int]()
        var candTurns = [Int]()
        var candHeur = [Int]()
        var seen = Set<UInt64>()

        depthLoop: for depth in 1...max(1, options.maxSteps) {
            let beamCount = beamPos.count
            candBoards.removeAll(keepingCapacity: true)
            candParent.removeAll(keepingCapacity: true)
            candPos.removeAll(keepingCapacity: true)
            candDir.removeAll(keepingCapacity: true)
            candTurns.removeAll(keepingCapacity: true)
            candHeur.removeAll(keepingCapacity: true)
            seen.removeAll(keepingCapacity: true)
            var work = [Int8](repeating: 0, count: N)

            for i in 0..<beamCount {
                let pos = beamPos[i]
                for (di, d) in dirs.enumerated() {
                    guard let np = BoardOps.neighbor(pos, d, size) else { continue }   // 盤面外は拒否
                    if np == beamPrev[i] { continue }                                   // 往復は除外
                    let off = i * N
                    for k in 0..<N { work[k] = beamBoards[off + k] }
                    work.swapAt(pos, np)

                    // 重複排除用のハッシュ（FNV-1a、実行ごとに同じ値）
                    var h: UInt64 = 0xcbf29ce484222325
                    for k in 0..<N { h = (h ^ UInt64(UInt8(bitPattern: work[k]))) &* 0x100000001b3 }
                    h = (h ^ UInt64(np)) &* 0x100000001b3
                    if !seen.insert(h).inserted { continue }

                    expanded += 1
                    let ev = evaluator.evaluate(raw: work)
                    let score = goalScore(ev, goals)
                    let turns = beamTurns[i] + ((beamDir[i] >= 0 && beamDir[i] != di) ? 1 : 0)
                    let pr = work.withUnsafeBufferPointer { pairs($0, size) }
                    let heur = score + pr * 40 - depth * 2 - turns

                    candBoards.append(contentsOf: work)
                    candParent.append(i)
                    candPos.append(np)
                    candDir.append(di)
                    candTurns.append(turns)
                    candHeur.append(heur)

                    if isBetter(score: score, steps: depth, turns: turns) {
                        bestDepth = depth - 1; bestParent = i; bestLast = np
                        bestRes = ev; bestScore = score; bestSteps = depth; bestTurns = turns
                    }

                    if expanded & 255 == 0 {
                        if cancel?.isCancelled == true { cancelled = true; stopped = true; break depthLoop }
                        if let dl = deadline, clock() > dl { stopped = true; break depthLoop }
                    }
                }
            }
            if candPos.isEmpty { break }
            if allGoalsMet(bestRes, goals, maxCombos: maxCombos) && bestSteps < depth { break }

            // 上位 beamWidth 件を残す（同点は生成順で決めるので結果は毎回同じ）
            var order = Array(0..<candPos.count)
            order.sort { a, b in candHeur[a] != candHeur[b] ? candHeur[a] > candHeur[b] : a < b }
            if order.count > beamWidth { order.removeSubrange(beamWidth...) }

            var nb = [Int8]()
            nb.reserveCapacity(order.count * N)
            var np = [Int](), npr = [Int](), nd = [Int](), nt = [Int]()
            var lp = [Int32](), lpos = [UInt8]()
            for idx in order {
                let off = idx * N
                nb.append(contentsOf: candBoards[off..<(off + N)])
                np.append(candPos[idx])
                npr.append(beamPos[candParent[idx]])
                nd.append(candDir[idx])
                nt.append(candTurns[idx])
                lp.append(Int32(candParent[idx]))
                lpos.append(UInt8(candPos[idx]))
            }
            beamBoards = nb; beamPos = np; beamPrev = npr; beamDir = nd; beamTurns = nt
            layerParent.append(lp)
            layerPos.append(lpos)

            if cancel?.isCancelled == true { cancelled = true; stopped = true; break }
            if let dl = deadline, clock() > dl { stopped = true; break }
        }

        // 経路を復元
        var path: [Int] = []
        if bestDepth >= 0 {
            path.append(bestLast)
            var d = bestDepth, i = bestParent
            while d >= 0 && i >= 0 {
                path.append(Int(layerPos[d][i]))
                i = Int(layerParent[d][i])
                d -= 1
            }
            path.reverse()
        } else {
            path = [0]
        }
        var moves: [Direction] = []
        if path.count >= 2 {
            for k in 1..<path.count {
                let a = path[k - 1], b = path[k]
                let dr = b / C - a / C, dc = b % C - a % C
                let m: Direction = dr == -1 ? .up : dr == 1 ? .down : dc == -1 ? .left : .right
                moves.append(m)
            }
        }
        return Route(size: size, start: path[0], path: path, moves: moves, result: bestRes,
                     score: bestScore, turns: bestTurns, elapsed: clock() - t0,
                     stoppedEarly: stopped, cancelled: cancelled, expanded: expanded)
    }
}

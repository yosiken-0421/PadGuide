import Foundation

/// 探索で優先する条件（リーダースキルの発動条件など）。
/// 条件の数え方は公式の説明（pad.gungho.jp「リーダースキル説明文の一部を調整」）に合わせる：
/// 「Nコンボ」「N色同時攻撃」「○のNコンボ」「○をN個つなげて消す」は、いずれも「N以上」で発動する。
public struct Goals: Codable, Equatable, Sendable {
    /// この色を多く消す（nil なら指定なし）
    public var priorityColor: OrbKind?
    public var heal: Bool
    public var fiveColors: Bool
    public var lShape: Bool
    public var cross: Bool
    public var row: Bool
    public var square: Bool
    public var tShape: Bool
    /// 形の条件の色（例：「回復の5個十字消し」。nil ならどの色でもよい）
    public var shapeColors: [ClearShape: OrbKind]

    /// Nコンボ以上（nil = 条件なし）
    public var minCombos: Int?
    /// Nコンボちょうど（落ちコンなしのリーダーなど）
    public var exactCombos: Int?
    /// N色以上同時攻撃（火・水・木・光・闇・回復のうち消した種類の数）
    public var minColors: Int?
    /// この色をすべて同時に消す（例：「火水の同時攻撃」）
    public var requiredColors: [OrbKind]
    /// ○をN個以上つなげて消す（connectColor が nil ならどの色でもよい）
    public var connectCount: Int?
    public var connectColor: OrbKind?
    /// ○のNコンボ以上
    public var colorComboKind: OrbKind?
    public var colorComboCount: Int?
    /// パズル後の残りドロップ数がN個以下
    public var maxRemaining: Int?

    public init(priorityColor: OrbKind? = nil, heal: Bool = false, fiveColors: Bool = false,
                lShape: Bool = false, cross: Bool = false, row: Bool = false, square: Bool = false,
                tShape: Bool = false, shapeColors: [ClearShape: OrbKind] = [:],
                minCombos: Int? = nil, exactCombos: Int? = nil, minColors: Int? = nil, requiredColors: [OrbKind] = [],
                connectCount: Int? = nil, connectColor: OrbKind? = nil,
                colorComboKind: OrbKind? = nil, colorComboCount: Int? = nil, maxRemaining: Int? = nil) {
        self.priorityColor = priorityColor
        self.heal = heal
        self.fiveColors = fiveColors
        self.lShape = lShape
        self.cross = cross
        self.row = row
        self.square = square
        self.tShape = tShape
        self.shapeColors = shapeColors
        self.minCombos = minCombos
        self.exactCombos = exactCombos
        self.minColors = minColors
        self.requiredColors = requiredColors
        self.connectCount = connectCount
        self.connectColor = connectColor
        self.colorComboKind = colorComboKind
        self.colorComboCount = colorComboCount
        self.maxRemaining = maxRemaining
    }

    enum CodingKeys: String, CodingKey {
        case priorityColor, heal, fiveColors, lShape, cross, row, square, tShape, shapeColors
        case minCombos, exactCombos, minColors, requiredColors, connectCount, connectColor
        case colorComboKind, colorComboCount, maxRemaining
    }

    /// 項目が増えても、以前に保存した設定をそのまま読めるようにする（ない項目は「条件なし」）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priorityColor = try c.decodeIfPresent(OrbKind.self, forKey: .priorityColor)
        heal = try c.decodeIfPresent(Bool.self, forKey: .heal) ?? false
        fiveColors = try c.decodeIfPresent(Bool.self, forKey: .fiveColors) ?? false
        lShape = try c.decodeIfPresent(Bool.self, forKey: .lShape) ?? false
        cross = try c.decodeIfPresent(Bool.self, forKey: .cross) ?? false
        row = try c.decodeIfPresent(Bool.self, forKey: .row) ?? false
        square = try c.decodeIfPresent(Bool.self, forKey: .square) ?? false
        tShape = try c.decodeIfPresent(Bool.self, forKey: .tShape) ?? false
        shapeColors = try c.decodeIfPresent([ClearShape: OrbKind].self, forKey: .shapeColors) ?? [:]
        minCombos = try c.decodeIfPresent(Int.self, forKey: .minCombos)
        exactCombos = try c.decodeIfPresent(Int.self, forKey: .exactCombos)
        minColors = try c.decodeIfPresent(Int.self, forKey: .minColors)
        requiredColors = try c.decodeIfPresent([OrbKind].self, forKey: .requiredColors) ?? []
        connectCount = try c.decodeIfPresent(Int.self, forKey: .connectCount)
        connectColor = try c.decodeIfPresent(OrbKind.self, forKey: .connectColor)
        colorComboKind = try c.decodeIfPresent(OrbKind.self, forKey: .colorComboKind)
        colorComboCount = try c.decodeIfPresent(Int.self, forKey: .colorComboCount)
        maxRemaining = try c.decodeIfPresent(Int.self, forKey: .maxRemaining)
    }

    var shapeGoals: [ClearShape] {
        var s: [ClearShape] = []
        if lShape { s.append(.lShape) }
        if cross { s.append(.cross) }
        if row { s.append(.row) }
        if square { s.append(.square) }
        if tShape { s.append(.tShape) }
        return s
    }

    /// 設定されているリーダースキルの条件の数
    public var leaderConditionCount: Int {
        var n = shapeGoals.count
        if minCombos != nil { n += 1 }
        if exactCombos != nil { n += 1 }
        if minColors != nil { n += 1 }
        if !requiredColors.isEmpty { n += 1 }
        if connectCount != nil { n += 1 }
        if colorComboKind != nil && colorComboCount != nil { n += 1 }
        if maxRemaining != nil { n += 1 }
        return n
    }
}

/// 評価結果を読むための共通の窓口（EvalResult と探索中の Evaluator の両方で同じ判定を使う）
protocol EvalView {
    var vCombos: Int { get }
    var vCleared: Int { get }
    func vClearedByKind(_ k: Int) -> Int
    func vCombosByKind(_ k: Int) -> Int
    func vMaxGroup(_ k: Int) -> Int
    /// 形を作ったか（kind が nil ならどの色でもよい）
    func vHasShape(_ s: ClearShape, kind: Int?) -> Bool
}

extension EvalResult: EvalView {
    var vCombos: Int { combos }
    var vCleared: Int { cleared }
    func vClearedByKind(_ k: Int) -> Int { clearedByKind[k] }
    func vCombosByKind(_ k: Int) -> Int { combosByKind[k] }
    func vMaxGroup(_ k: Int) -> Int { maxGroupByKind[k] }
    func vHasShape(_ s: ClearShape, kind: Int?) -> Bool {
        guard let k = kind else { return shapes.contains(s) }
        guard let o = OrbKind(rawValue: Int8(k)) else { return false }
        return shapesByKind[o]?.contains(s) ?? false
    }
}

extension Evaluator: EvalView {
    var vCombos: Int { qCombos }
    var vCleared: Int { qCleared }
    func vClearedByKind(_ k: Int) -> Int { qClearedByKind[k] }
    func vCombosByKind(_ k: Int) -> Int { qCombosByKind[k] }
    func vMaxGroup(_ k: Int) -> Int { qMaxGroupByKind[k] }
    func vHasShape(_ s: ClearShape, kind: Int?) -> Bool {
        let bit = UInt8(1) << UInt8(ClearShape.allCases.firstIndex(of: s)!)
        if let k = kind { return qShapeKinds[k] & bit != 0 }
        return qShapes & bit != 0
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
    /// 敵の妨害による縛り（開始位置固定・操作不可など）。盤面の大きさが違えば使わない
    public var constraints: BoardConstraints?

    public init(maxSteps: Int = SolverOptions.defaultSteps, timeLimit: Double? = 1, beamWidth: Int = 800,
                maxBeamWidth: Int = 12_000, goals: Goals = Goals(), constraints: BoardConstraints? = nil) {
        self.maxSteps = maxSteps
        self.timeLimit = timeLimit
        self.beamWidth = beamWidth
        self.maxBeamWidth = maxBeamWidth
        self.goals = goals
        self.constraints = constraints
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
        a += leaderConditions(goals).filter { $0.1 }.map { $0.0 }
        return a
    }

    /// 満たせなかったリーダースキルの条件
    public func missed(_ goals: Goals) -> [String] {
        leaderConditions(goals).filter { !$0.1 }.map { $0.0 }
    }

    /// リーダースキルの条件ごとの（名前, 満たしたか）
    public func leaderConditions(_ goals: Goals) -> [(String, Bool)] {
        let r = result
        var out: [(String, Bool)] = []
        for shape in goals.shapeGoals {
            let color = goals.shapeColors[shape]
            out.append(((color.map { $0.label + "の" } ?? "") + shape.rawValue + "消し",
                        r.vHasShape(shape, kind: color.map { Int($0.rawValue) })))
        }
        if let n = goals.minCombos { out.append(("\(n)コンボ以上", r.combos >= n)) }
        if let n = goals.exactCombos { out.append(("\(n)コンボちょうど", r.combos == n)) }
        if let n = goals.minColors { out.append(("\(n)色同時攻撃", r.colorCount >= n)) }
        if !goals.requiredColors.isEmpty {
            out.append((goals.requiredColors.map { $0.label }.joined() + "の同時攻撃",
                        goals.requiredColors.allSatisfy { r.combosByKind[Int($0.rawValue)] > 0 }))
        }
        if let n = goals.connectCount {
            out.append(((goals.connectColor.map { $0.label + "を" } ?? "") + "\(n)個つなげて消す",
                        Solver.maxGroup(r, goals.connectColor) >= n))
        }
        if let k = goals.colorComboKind, let n = goals.colorComboCount {
            out.append(("\(k.label)の\(n)コンボ", r.combosByKind[Int(k.rawValue)] >= n))
        }
        if let n = goals.maxRemaining {
            out.append(("残りドロップ\(n)個以下", size.count - r.cleared <= n))
        }
        return out
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
    public static func goalScore(_ r: EvalResult, _ goals: Goals, cellCount: Int = 30) -> Int {
        score(r, goals, cellCount: cellCount)
    }

    static func allGoalsMet(_ r: EvalResult, _ goals: Goals, maxCombos: Int, cellCount: Int = 30) -> Bool {
        met(r, goals, maxCombos: maxCombos, cellCount: cellCount)
    }

    /// 条件ごとの達成（リーダースキルの条件は、満たせば大きく加点。満たせなくても近いほど少し加点して探索を導く）
    static func score<V: EvalView>(_ r: V, _ goals: Goals, cellCount: Int) -> Int {
        var s = r.vCombos * 10_000 + r.vCleared * 10
        if let pc = goals.priorityColor {
            let i = Int(pc.rawValue)
            s += r.vClearedByKind(i) * 400 + (r.vCombosByKind(i) > 0 ? 3_000 : 0)
        }
        let heart = Int(OrbKind.heart.rawValue)
        if goals.heal { s += (r.vClearedByKind(heart) > 0 ? 3_000 : 0) + r.vClearedByKind(heart) * 100 }
        if goals.fiveColors && fiveColors(r) { s += 30_000 }
        for shape in goals.shapeGoals where r.vHasShape(shape, kind: goals.shapeColors[shape].map { Int($0.rawValue) }) {
            s += 30_000
        }
        if let n = goals.minCombos, r.vCombos >= n { s += 30_000 }
        if let n = goals.exactCombos {
            if r.vCombos == n { s += 30_000 } else if r.vCombos > n { s -= (r.vCombos - n) * 20_000 }
        }
        if let n = goals.minColors {
            let c = colorCount(r)
            s += c >= n ? 30_000 : c * 1_000
        }
        if !goals.requiredColors.isEmpty {
            let got = goals.requiredColors.filter { r.vCombosByKind(Int($0.rawValue)) > 0 }.count
            s += got == goals.requiredColors.count ? 30_000 : got * 1_000
        }
        if let n = goals.connectCount {
            let g = maxGroup(r, goals.connectColor)
            s += g >= n ? 30_000 : g * 500
        }
        if let k = goals.colorComboKind, let n = goals.colorComboCount {
            let c = r.vCombosByKind(Int(k.rawValue))
            s += c >= n ? 30_000 : c * 2_000
        }
        if let n = goals.maxRemaining {
            let rem = cellCount - r.vCleared
            s += rem <= n ? 30_000 : -(rem - n) * 50
        }
        return s
    }

    static func met<V: EvalView>(_ r: V, _ goals: Goals, maxCombos: Int, cellCount: Int) -> Bool {
        if let n = goals.exactCombos {
            if r.vCombos != n { return false }
        } else if r.vCombos < maxCombos {
            return false
        }
        if goals.fiveColors && !fiveColors(r) { return false }
        for shape in goals.shapeGoals where !r.vHasShape(shape, kind: goals.shapeColors[shape].map { Int($0.rawValue) }) {
            return false
        }
        if goals.heal && r.vClearedByKind(Int(OrbKind.heart.rawValue)) == 0 { return false }
        if let pc = goals.priorityColor, r.vCombosByKind(Int(pc.rawValue)) == 0 { return false }
        if let n = goals.minCombos, r.vCombos < n { return false }
        if let n = goals.minColors, colorCount(r) < n { return false }
        if goals.requiredColors.contains(where: { r.vCombosByKind(Int($0.rawValue)) == 0 }) { return false }
        if let n = goals.connectCount, maxGroup(r, goals.connectColor) < n { return false }
        if let k = goals.colorComboKind, let n = goals.colorComboCount, r.vCombosByKind(Int(k.rawValue)) < n { return false }
        if let n = goals.maxRemaining, cellCount - r.vCleared > n { return false }
        return true
    }

    static func fiveColors<V: EvalView>(_ r: V) -> Bool {
        for k in 0...4 where r.vCombosByKind(k) == 0 { return false }
        return true
    }

    /// 同時攻撃の色数（火・水・木・光・闇・回復）
    static func colorCount<V: EvalView>(_ r: V) -> Int {
        var n = 0
        for k in 0...5 where r.vCombosByKind(k) > 0 { n += 1 }
        return n
    }

    /// 一度につなげて消した最大の個数（色の指定がなければ、どの色でも）
    static func maxGroup<V: EvalView>(_ r: V, _ color: OrbKind?) -> Int {
        if let c = color { return r.vMaxGroup(Int(c.rawValue)) }
        var m = 0
        for k in 0..<Evaluator.kindCount where r.vMaxGroup(k) > m { m = r.vMaxGroup(k) }
        return m
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
        // 縛り：雲・ルーレット・消せない色は「消えないドロップ」として計算し、通れないマス・開始位置を守る
        let cons = options.constraints?.effective(for: size)
        let work = cons?.solvingBoard(board) ?? board
        let maxCombos = theoreticalMaxCombos(work)
        let maxSteps = max(1, options.maxSteps)
        let base = work.raw
        let starts = cons?.startCells() ?? Array(0..<size.count)
        let enter = (0..<size.count).map { cons?.canEnter($0) ?? true }

        // 何も動かさない状態
        let ev0 = evaluator.evaluate(raw: base)
        var best = RunResult()
        best.path = [starts.first ?? 0]
        best.score = goalScore(ev0, goals, cellCount: size.count)
        best.met = allGoalsMet(ev0, goals, maxCombos: maxCombos, cellCount: size.count)

        var width = max(1, options.beamWidth)
        var stopped = false, cancelled = false, expanded = 0
        while true {
            let runStart = clock()
            let r = beamRun(base: base, size: size, width: width, maxSteps: maxSteps, goals: goals,
                            maxCombos: maxCombos, evaluator: evaluator, deadline: deadline, cancel: cancel, clock: clock,
                            starts: starts, enter: enter)
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
                     score: goalScore(result, goals, cellCount: size.count), turns: best.turns, elapsed: clock() - t0,
                     stoppedEarly: stopped, cancelled: cancelled, expanded: expanded)
    }

    /// 探索幅 width のビームサーチを1回行う
    static func beamRun(base: [Int8], size: BoardSize, width: Int, maxSteps: Int, goals: Goals, maxCombos: Int,
                        evaluator: Evaluator, deadline: Double?, cancel: CancellationFlag?,
                        clock: () -> Double, starts: [Int], enter: [Bool]) -> RunResult {
        let N = size.count
        let dirs = Direction.allCases
        let wantShapes = !goals.shapeGoals.isEmpty
        // 隣のマス（盤面外は -1）
        var nbr = [Int](repeating: -1, count: N * 4)
        for p in 0..<N {
            for (di, d) in dirs.enumerated() {
                if let q = BoardOps.neighbor(p, d, size), enter[q] { nbr[p * 4 + di] = q }   // 通れないマスへは進まない
            }
        }

        let beamCap = max(width, N)
        let candCap = beamCap * 4
        let beamBoards = UnsafeMutablePointer<Int8>.allocate(capacity: beamCap * N)
        let candBoards = UnsafeMutablePointer<Int8>.allocate(capacity: candCap * N)
        defer { beamBoards.deallocate(); candBoards.deallocate() }

        var beamPos = [Int](), beamPrev = [Int](), beamDir = [Int](), beamTurns = [Int]()
        beamPos.reserveCapacity(beamCap); beamPrev.reserveCapacity(beamCap)
        beamDir.reserveCapacity(beamCap); beamTurns.reserveCapacity(beamCap)
        for (j, p) in starts.enumerated() {
            for k in 0..<N { beamBoards[j * N + k] = base[k] }
            beamPos.append(p); beamPrev.append(-1); beamDir.append(-1); beamTurns.append(0)
        }
        // 経路復元用：深さごとの (親の index, 位置)
        var layerParent: [[Int32]] = [[Int32](repeating: -1, count: starts.count)]
        var layerPos: [[UInt8]] = [starts.map { UInt8($0) }]

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
                    let score = Self.score(evaluator, goals, cellCount: N)
                    let turns = beamTurns[i] + ((beamDir[i] >= 0 && beamDir[i] != di) ? 1 : 0)
                    let heur = score - evaluator.qCleared * 10 + potential(UnsafePointer(w), size, evaluator) - turns

                    candParent.append(i); candPos.append(np); candDir.append(di)
                    candTurns.append(turns); candHeur.append(heur)

                    if score > res.score || (score == res.score && (depth < res.steps || (depth == res.steps && turns < res.turns))) {
                        bestDepth = depth - 1; bestParent = i; bestLast = np
                        res.score = score; res.steps = depth; res.turns = turns
                        res.met = met(evaluator, goals, maxCombos: maxCombos, cellCount: N)
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

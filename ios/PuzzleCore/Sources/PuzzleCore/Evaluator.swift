import Foundation

/// 消し方の形
public enum ClearShape: String, Codable, CaseIterable, Sendable {
    case lShape = "L字"
    case cross = "十字"
    case row = "横1列"
    case square = "3×3正方形"
    case tShape = "T字"
}

/// ルート終了後の盤面を評価した結果（落ちコンなし・盤面内の連鎖はあり）
public struct EvalResult: Equatable, Sendable {
    public var combos = 0
    public var cleared = 0
    /// OrbKind.rawValue ごとの消去数
    public var clearedByKind = [Int](repeating: 0, count: OrbKind.allCases.count)
    /// OrbKind.rawValue ごとのコンボ数
    public var combosByKind = [Int](repeating: 0, count: OrbKind.allCases.count)
    public var shapes: Set<ClearShape> = []
    /// OrbKind.rawValue ごとの、一度につなげて消した最大の個数
    public var maxGroupByKind = [Int](repeating: 0, count: OrbKind.allCases.count)
    /// 色ごとの消し方の形
    public var shapesByKind: [OrbKind: Set<ClearShape>] = [:]

    public init() {}

    public var healCleared: Int { clearedByKind[Int(OrbKind.heart.rawValue)] }
    /// 同時攻撃の色数（火・水・木・光・闇・回復のうち消した種類の数）
    public var colorCount: Int { (0...5).filter { combosByKind[$0] > 0 }.count }
    /// 火水木光闇をすべて消したか
    public var fiveColors: Bool { (0...4).allSatisfy { combosByKind[$0] > 0 } }
}

/// 消去・落下・連鎖の計算。作業用の領域を使い回すため、1インスタンスを複数スレッドで共有しないこと。
/// 探索では1秒に数十万回呼ぶので、評価ごとのメモリ確保をしない作りにしている。
public final class Evaluator {
    public let size: BoardSize
    private let n: Int
    private let g: UnsafeMutablePointer<Int8>
    private let mark: UnsafeMutablePointer<Bool>
    private let visited: UnsafeMutablePointer<Bool>
    private let inGroup: UnsafeMutablePointer<Bool>
    private let stack: UnsafeMutablePointer<Int>
    private let group: UnsafeMutablePointer<Int>
    private var groupCount = 0

    static let kindCount = OrbKind.allCases.count

    // 直前の評価結果（探索用。evaluate を呼ぶたびに上書き）
    private(set) var qCombos = 0
    private(set) var qCleared = 0
    let qClearedByKind: UnsafeMutablePointer<Int>
    let qCombosByKind: UnsafeMutablePointer<Int>
    /// 種類ごとの、一度につなげて消した最大の個数
    let qMaxGroupByKind: UnsafeMutablePointer<Int>
    /// 種類ごとの消し方の形（ClearShape.allCases の順のビット）
    let qShapeKinds: UnsafeMutablePointer<UInt8>
    /// ClearShape.allCases の順のビット
    private(set) var qShapes: UInt8 = 0

    public init(size: BoardSize) {
        self.size = size
        n = size.count
        g = .allocate(capacity: n); g.initialize(repeating: -1, count: n)
        mark = .allocate(capacity: n); mark.initialize(repeating: false, count: n)
        visited = .allocate(capacity: n); visited.initialize(repeating: false, count: n)
        inGroup = .allocate(capacity: n); inGroup.initialize(repeating: false, count: n)
        stack = .allocate(capacity: n); stack.initialize(repeating: 0, count: n)
        group = .allocate(capacity: n); group.initialize(repeating: 0, count: n)
        qClearedByKind = .allocate(capacity: Self.kindCount); qClearedByKind.initialize(repeating: 0, count: Self.kindCount)
        qCombosByKind = .allocate(capacity: Self.kindCount); qCombosByKind.initialize(repeating: 0, count: Self.kindCount)
        qMaxGroupByKind = .allocate(capacity: Self.kindCount); qMaxGroupByKind.initialize(repeating: 0, count: Self.kindCount)
        qShapeKinds = .allocate(capacity: Self.kindCount); qShapeKinds.initialize(repeating: 0, count: Self.kindCount)
    }

    deinit {
        g.deallocate(); mark.deallocate(); visited.deallocate(); inGroup.deallocate()
        stack.deallocate(); group.deallocate(); qClearedByKind.deallocate(); qCombosByKind.deallocate()
        qMaxGroupByKind.deallocate(); qShapeKinds.deallocate()
    }

    public func evaluate(_ board: Board) -> EvalResult {
        evaluate(raw: board.raw)
    }

    /// raw: OrbKind.rawValue の配列（-1 は空き）
    public func evaluate(raw: [Int8]) -> EvalResult {
        precondition(raw.count == n)
        raw.withUnsafeBufferPointer { run($0.baseAddress!, shapes: true) }
        var res = EvalResult()
        res.combos = qCombos
        res.cleared = qCleared
        for k in 0..<Self.kindCount {
            res.clearedByKind[k] = qClearedByKind[k]
            res.combosByKind[k] = qCombosByKind[k]
            res.maxGroupByKind[k] = qMaxGroupByKind[k]
            if qShapeKinds[k] != 0, let kind = OrbKind(rawValue: Int8(k)) {
                var set: Set<ClearShape> = []
                for (i, s) in ClearShape.allCases.enumerated() where qShapeKinds[k] & (1 << UInt8(i)) != 0 { set.insert(s) }
                res.shapesByKind[kind] = set
            }
        }
        for (i, s) in ClearShape.allCases.enumerated() where qShapes & (1 << UInt8(i)) != 0 { res.shapes.insert(s) }
        return res
    }

    /// 探索用の評価。結果は qCombos などに入る。shapes が false なら形の判定を省く（速い）
    func run(_ src: UnsafePointer<Int8>, shapes: Bool) {
        let C = size.cols, R = size.rows, N = n
        let g = self.g, mark = self.mark, visited = self.visited, stack = self.stack, group = self.group
        for i in 0..<N { g[i] = src[i] }
        qCombos = 0; qCleared = 0; qShapes = 0
        for k in 0..<Self.kindCount { qClearedByKind[k] = 0; qCombosByKind[k] = 0; qMaxGroupByKind[k] = 0; qShapeKinds[k] = 0 }
        let unknown = OrbKind.unknown.rawValue

        while true {
            for i in 0..<N { mark[i] = false }
            var any = false
            // 横に3個以上
            if C >= 3 {
                for r in 0..<R {
                    let base = r * C
                    for c in 0...(C - 3) {
                        let i = base + c
                        let v = g[i]
                        if v >= 0 && v != unknown && g[i + 1] == v && g[i + 2] == v {
                            mark[i] = true; mark[i + 1] = true; mark[i + 2] = true; any = true
                        }
                    }
                }
            }
            // 縦に3個以上
            if R >= 3 {
                for i in 0..<(N - 2 * C) {
                    let v = g[i]
                    if v >= 0 && v != unknown && g[i + C] == v && g[i + 2 * C] == v {
                        mark[i] = true; mark[i + C] = true; mark[i + 2 * C] = true; any = true
                    }
                }
            }
            if !any { break }

            // 消える同色のマスで、縦横につながっているものを1コンボにまとめる
            for i in 0..<N { visited[i] = false }
            for i in 0..<N where mark[i] && !visited[i] {
                let color = g[i]
                var sp = 0
                groupCount = 0
                stack[sp] = i; sp += 1
                visited[i] = true
                while sp > 0 {
                    sp -= 1
                    let p = stack[sp]
                    group[groupCount] = p; groupCount += 1
                    let pc = p % C
                    var q = p - C
                    if q >= 0 && mark[q] && !visited[q] && g[q] == color { visited[q] = true; stack[sp] = q; sp += 1 }
                    q = p + C
                    if q < N && mark[q] && !visited[q] && g[q] == color { visited[q] = true; stack[sp] = q; sp += 1 }
                    if pc > 0 {
                        q = p - 1
                        if mark[q] && !visited[q] && g[q] == color { visited[q] = true; stack[sp] = q; sp += 1 }
                    }
                    if pc < C - 1 {
                        q = p + 1
                        if mark[q] && !visited[q] && g[q] == color { visited[q] = true; stack[sp] = q; sp += 1 }
                    }
                }
                qCombos += 1
                qCleared += groupCount
                qCombosByKind[Int(color)] += 1
                qClearedByKind[Int(color)] += groupCount
                if groupCount > qMaxGroupByKind[Int(color)] { qMaxGroupByKind[Int(color)] = groupCount }
                if shapes { detectShapes(Int(color)) }
            }

            for i in 0..<N where mark[i] { g[i] = -1 }
            // 落下
            for c in 0..<C {
                var w = (R - 1) * C + c
                var i = w
                while i >= 0 {
                    let v = g[i]
                    if v != -1 { g[w] = v; w -= C }
                    i -= C
                }
                while w >= 0 { g[w] = -1; w -= C }
            }
        }
    }

    private func bit(_ s: ClearShape) -> UInt8 {
        UInt8(1) << UInt8(ClearShape.allCases.firstIndex(of: s)!)
    }

    /// 直前に作った group の形を判定
    private func detectShapes(_ kind: Int) {
        let before = qShapes
        qShapes = 0
        detectShapesCore()
        qShapeKinds[kind] |= qShapes
        qShapes |= before
    }

    private func detectShapesCore() {
        let C = size.cols, R = size.rows
        let cnt = groupCount
        guard cnt == 5 || cnt == 9 || cnt >= C else { return }
        for k in 0..<cnt { inGroup[group[k]] = true }
        defer { for k in 0..<cnt { inGroup[group[k]] = false } }

        // 横1列：ある行のマスがすべて含まれる
        if cnt >= C {
            for r in 0..<R {
                var full = true
                for c in 0..<C where !inGroup[r * C + c] { full = false; break }
                if full { qShapes |= bit(.row); break }
            }
        }
        if cnt == 5 {
            for k in 0..<cnt {
                let p = group[k]
                let r = p / C, c = p % C
                // 十字：中心の上下左右がすべて含まれる
                if r > 0, r < R - 1, c > 0, c < C - 1,
                   inGroup[p - C], inGroup[p + C], inGroup[p - 1], inGroup[p + 1] {
                    qShapes |= bit(.cross)
                }
                // T字：横に3個（中心がここ）＋中心から縦に2個、または縦に3個＋中心から横に2個
                if c > 0, c < C - 1, inGroup[p - 1], inGroup[p + 1] {
                    if r + 2 < R, inGroup[p + C], inGroup[p + 2 * C] { qShapes |= bit(.tShape) }
                    if r >= 2, inGroup[p - C], inGroup[p - 2 * C] { qShapes |= bit(.tShape) }
                }
                if r > 0, r < R - 1, inGroup[p - C], inGroup[p + C] {
                    if c + 2 < C, inGroup[p + 1], inGroup[p + 2] { qShapes |= bit(.tShape) }
                    if c >= 2, inGroup[p - 1], inGroup[p - 2] { qShapes |= bit(.tShape) }
                }
                // L字：角から横に3個、縦に3個
                for dc in [-1, 1] {
                    for dr in [-1, 1] {
                        let c2 = c + 2 * dc, r2 = r + 2 * dr
                        guard c2 >= 0, c2 < C, r2 >= 0, r2 < R else { continue }
                        if inGroup[p + dc], inGroup[p + 2 * dc],
                           inGroup[p + dr * C], inGroup[p + 2 * dr * C] {
                            qShapes |= bit(.lShape)
                        }
                    }
                }
            }
        }
        if cnt == 9 {
            var r0 = Int.max, r1 = Int.min, c0 = Int.max, c1 = Int.min
            for k in 0..<cnt {
                let p = group[k]
                r0 = min(r0, p / C); r1 = max(r1, p / C)
                c0 = min(c0, p % C); c1 = max(c1, p % C)
            }
            if r1 - r0 == 2, c1 - c0 == 2 { qShapes |= bit(.square) }
        }
    }
}

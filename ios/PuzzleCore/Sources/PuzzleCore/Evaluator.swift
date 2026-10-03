import Foundation

/// 消し方の形
public enum ClearShape: String, Codable, CaseIterable, Sendable {
    case lShape = "L字"
    case cross = "十字"
    case row = "横1列"
    case square = "3×3正方形"
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

    public init() {}

    public var healCleared: Int { clearedByKind[Int(OrbKind.heart.rawValue)] }
    /// 火水木光闇をすべて消したか
    public var fiveColors: Bool { (0...4).allSatisfy { combosByKind[$0] > 0 } }
}

/// 消去・落下・連鎖の計算。作業用配列を使い回すため、1インスタンスを複数スレッドで共有しないこと。
public final class Evaluator {
    public let size: BoardSize
    private var g: [Int8]
    private var mark: [Bool]
    private var visited: [Bool]
    private var inGroup: [Bool]
    private var stack: [Int]
    private var group: [Int]

    public init(size: BoardSize) {
        self.size = size
        let n = size.count
        g = [Int8](repeating: -1, count: n)
        mark = [Bool](repeating: false, count: n)
        visited = [Bool](repeating: false, count: n)
        inGroup = [Bool](repeating: false, count: n)
        stack = []
        stack.reserveCapacity(n)
        group = []
        group.reserveCapacity(n)
    }

    public func evaluate(_ board: Board) -> EvalResult {
        evaluate(raw: board.raw)
    }

    /// raw: OrbKind.rawValue の配列（-1 は空き）
    public func evaluate(raw: [Int8]) -> EvalResult {
        let C = size.cols, R = size.rows, N = size.count
        precondition(raw.count == N)
        for i in 0..<N { g[i] = raw[i] }
        var res = EvalResult()
        let unknown = OrbKind.unknown.rawValue

        while true {
            for i in 0..<N { mark[i] = false }
            var any = false
            // 横に3個以上
            if C >= 3 {
                for r in 0..<R {
                    for c in 0...(C - 3) {
                        let i = r * C + c
                        let v = g[i]
                        if v >= 0 && v != unknown && g[i + 1] == v && g[i + 2] == v {
                            mark[i] = true; mark[i + 1] = true; mark[i + 2] = true; any = true
                        }
                    }
                }
            }
            // 縦に3個以上
            if R >= 3 {
                for r in 0...(R - 3) {
                    for c in 0..<C {
                        let i = r * C + c
                        let v = g[i]
                        if v >= 0 && v != unknown && g[i + C] == v && g[i + 2 * C] == v {
                            mark[i] = true; mark[i + C] = true; mark[i + 2 * C] = true; any = true
                        }
                    }
                }
            }
            if !any { break }

            // 消える同色のマスで、縦横につながっているものを1コンボにまとめる
            for i in 0..<N { visited[i] = false }
            for i in 0..<N where mark[i] && !visited[i] {
                let color = g[i]
                group.removeAll(keepingCapacity: true)
                stack.removeAll(keepingCapacity: true)
                stack.append(i)
                visited[i] = true
                while let p = stack.popLast() {
                    group.append(p)
                    let pr = p / C, pc = p % C
                    if pr > 0 { push(p - C, color) }
                    if pr < R - 1 { push(p + C, color) }
                    if pc > 0 { push(p - 1, color) }
                    if pc < C - 1 { push(p + 1, color) }
                }
                res.combos += 1
                res.cleared += group.count
                res.combosByKind[Int(color)] += 1
                res.clearedByKind[Int(color)] += group.count
                detectShapes(into: &res.shapes)
            }

            for i in 0..<N where mark[i] { g[i] = -1 }
            // 落下
            for c in 0..<C {
                var w = R - 1
                for r in stride(from: R - 1, through: 0, by: -1) {
                    let v = g[r * C + c]
                    if v != -1 {
                        g[w * C + c] = v
                        w -= 1
                    }
                }
                while w >= 0 {
                    g[w * C + c] = -1
                    w -= 1
                }
            }
        }
        return res
    }

    private func push(_ q: Int, _ color: Int8) {
        if mark[q] && !visited[q] && g[q] == color {
            visited[q] = true
            stack.append(q)
        }
    }

    /// 直前に作った group の形を判定
    private func detectShapes(into shapes: inout Set<ClearShape>) {
        let C = size.cols, R = size.rows
        let n = group.count
        guard n == 5 || n == 9 || n >= C else { return }
        for p in group { inGroup[p] = true }
        defer { for p in group { inGroup[p] = false } }

        // 横1列：ある行のマスがすべて含まれる
        if n >= C {
            for r in 0..<R {
                var full = true
                for c in 0..<C where !inGroup[r * C + c] { full = false; break }
                if full { shapes.insert(.row); break }
            }
        }
        if n == 5 {
            for p in group {
                let r = p / C, c = p % C
                // 十字：中心の上下左右がすべて含まれる
                if r > 0, r < R - 1, c > 0, c < C - 1,
                   inGroup[p - C], inGroup[p + C], inGroup[p - 1], inGroup[p + 1] {
                    shapes.insert(.cross)
                }
                // L字：角から横に3個、縦に3個
                for dc in [-1, 1] {
                    for dr in [-1, 1] {
                        let c2 = c + 2 * dc, r2 = r + 2 * dr
                        guard c2 >= 0, c2 < C, r2 >= 0, r2 < R else { continue }
                        if inGroup[p + dc], inGroup[p + 2 * dc],
                           inGroup[p + dr * C], inGroup[p + 2 * dr * C] {
                            shapes.insert(.lShape)
                        }
                    }
                }
            }
        }
        if n == 9 {
            let rows = group.map { $0 / C }, cols = group.map { $0 % C }
            if let r0 = rows.min(), let r1 = rows.max(), let c0 = cols.min(), let c1 = cols.max(),
               r1 - r0 == 2, c1 - c0 == 2 {
                shapes.insert(.square)
            }
        }
    }
}

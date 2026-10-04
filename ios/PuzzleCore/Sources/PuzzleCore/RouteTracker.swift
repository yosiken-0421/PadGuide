import Foundation

/// ルートのどこまで操作が進んだかを、画面の盤面から推定する。
/// ルートの各手順の後の盤面をあらかじめ作っておき、今の盤面と最も一致するものを探す。
/// （指で持っているドロップは読み違えやすいので、数マスの違いは許す）
public struct RouteTracker: Sendable {
    public let path: [Int]
    public let steps: Int
    /// ルートの各手順の後の盤面（先頭が動かす前）
    public let boards: [[OrbKind]]
    public private(set) var progress = 0
    public private(set) var offRoute = false
    private var missCount = 0

    /// 違ってよいマス数（持っているドロップ・途中の描画のぶん）
    public static let tolerance = 3

    public init?(board: Board, path: [Int]) {
        guard path.count >= 2, path.allSatisfy({ $0 >= 0 && $0 < board.size.count }) else { return nil }
        self.path = path
        steps = path.count - 1
        var b = board.cells
        var list = [b]
        for k in 1..<path.count {
            b.swapAt(path[k - 1], path[k])
            list.append(b)
        }
        boards = list
    }

    /// 同じ一致度のとき（同じ色どうしを入れ替えた手は前後の盤面が同じになり、区別できない）：
    /// 先へ進みすぎて手順を飛ばさないよう、今の位置以降でいちばん手前の手を選ぶ。
    /// 盤面が変われば次の更新で追いつく。今の位置以降の候補がなければ、今の位置に近いほう。
    static func prefer(_ k: Int, over best: Int, progress: Int) -> Bool {
        if best < 0 { return true }
        let kAhead = k >= progress, bAhead = best >= progress
        if kAhead && bAhead { return k < best }
        if kAhead != bAhead { return kAhead }
        return abs(k - progress) < abs(best - progress)
    }

    static func mismatch(_ a: [OrbKind], _ b: [OrbKind]) -> Int {
        guard a.count == b.count else { return Int.max }
        var n = 0
        for i in a.indices where a[i] != b[i] { n += 1 }
        return n
    }

    /// 今の盤面を渡す。進み具合や「ルートから外れた」が変わったら true
    @discardableResult
    public mutating func update(_ cells: [OrbKind]) -> Bool {
        var best = -1, bestMiss = Int.max
        for (k, b) in boards.enumerated() {
            let m = Self.mismatch(cells, b)
            if m < bestMiss || (m == bestMiss && Self.prefer(k, over: best, progress: progress)) {
                best = k; bestMiss = m
            }
        }
        let before = (progress, offRoute)
        if bestMiss <= Self.tolerance {
            progress = best
            offRoute = false
            missCount = 0
        } else {
            missCount += 1
            if missCount >= 2 { offRoute = true }   // 2回続けて合わなければ「外れた」
        }
        return before != (progress, offRoute)
    }

    /// 最初からやり直す（指を離して次のターンになったときなど）
    public mutating func reset() {
        progress = 0
        offRoute = false
        missCount = 0
    }
}

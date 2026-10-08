import Foundation

/// ルーレット（指定されたマスのドロップが一定間隔で別の色に変わり続ける敵の妨害）を、画面の変化から自動で見つける。
///
/// 見た目（枠の絵）は使わず、動きだけで判断する：
/// - 盤面のほかのマスが止まっている（ドロップを動かしていない・コンボで消えていない）間に
/// - 同じマスが何度も、3種類以上の色に変わり続けていたら、そのマスをルーレットとみなす
///
/// ドロップを動かしている最中や盤面が大きく変わっている最中は判断しない（見つけたマスもそのまま）。
/// 一度見つけたマスは、盤面が止まっている間にしばらく変わらなくなったら外す。
public struct RouletteDetector: Sendable {
    /// 判断に使う直近のフレーム数（画面共有側は 1 秒に約 4 回読むので、約 4 秒分）
    public static let window = 16
    /// 判断を始めるのに必要なフレーム数（約 3 秒）
    public static let minFrames = 12
    /// ルーレットとみなすマス数の上限（これより多く変わるのは、ルーレットではなく盤面の変化）
    public static let maxCells = 8

    private var history: [[OrbKind]] = []
    /// 見つけたルーレットのマス
    public private(set) var cells: Set<Int> = []

    public init() {}

    public mutating func reset() {
        history.removeAll()
        cells.removeAll()
    }

    /// 1 フレーム分の読み取り結果を渡す。見つけたマスが変わったら true
    @discardableResult
    public mutating func feed(_ kinds: [OrbKind]) -> Bool {
        if let last = history.last, last.count != kinds.count {   // 盤面の大きさが変わった
            let had = !cells.isEmpty
            reset()
            history.append(kinds)
            return had
        }
        history.append(kinds)
        if history.count > Self.window { history.removeFirst(history.count - Self.window) }
        guard history.count >= Self.minFrames else { return false }

        let n = kinds.count
        var changes = [Int](repeating: 0, count: n)
        var colors = [Set<OrbKind>](repeating: [], count: n)
        for i in 0..<n {
            for f in history where f[i].isAttackOrHeart { colors[i].insert(f[i]) }
        }
        for k in 1..<history.count {
            for i in 0..<n where history[k][i] != history[k - 1][i] { changes[i] += 1 }
        }
        // ルーレットらしいマス：何度も変わり、色ドロップの3種類以上を行き来している
        let cycling = Set((0..<n).filter { changes[$0] >= 2 && colors[$0].count >= 3 })
        // それ以外のマスは止まっているか（読み違いのちらつき程度は許す）
        let others = (0..<n).filter { !cycling.contains($0) && !cells.contains($0) }
        let otherChanges = others.reduce(0) { $0 + changes[$1] }
        let boardStill = otherChanges <= history.count / 4
        guard boardStill, cycling.count <= Self.maxCells else { return false }   // 動かしている最中などは判断しない

        var next = cells.union(cycling)
        // 止まっている盤面で、しばらく変わっていないマスは外す（ルーレットの効果が切れた）
        for i in cells where changes[i] == 0 { next.remove(i) }
        let changed = next != cells
        cells = next
        return changed
    }
}

extension OrbKind {
    /// 火・水・木・光・闇・回復（ルーレットが変わる色）
    var isAttackOrHeart: Bool { rawValue <= 5 }
}

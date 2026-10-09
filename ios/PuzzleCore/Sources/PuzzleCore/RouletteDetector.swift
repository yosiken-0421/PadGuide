import Foundation

/// ルーレット（指定されたマスのドロップが一定間隔で別の色に変わり続ける敵の妨害）を、画面の変化から自動で見つける。
///
/// 見た目（枠の絵）は使わず、動きだけで判断する：
/// - 盤面のほかのマスが止まっている（ドロップを動かしていない・コンボで消えていない）間に
/// - 同じマスが何度も、3種類以上の色に変わり続けていたら、そのマスをルーレットとみなす
///
/// さらに、ルーレットは「火→水→木→光→闇→回復」の決まった順に変わる（攻略サイトの説明）。
/// この順番どおりに3回以上続けて変わったマスは、ドロップを動かしている最中でもルーレットとみなす
/// （動かしたり読み違えたりして変わるときは、色がこの順に続くことはほとんどない）。
/// 一度見つけたマスは、盤面が止まっている間にしばらく変わらなくなったら外す。
public struct RouletteDetector: Sendable {
    /// 判断に使う直近のフレーム数（画面共有側は 1 秒に約 4 回読むので、約 6 秒分。
    /// ルーレットの間隔は敵によって違う（攻略サイトの例では 1 秒・0.5 秒）ので、遅めでも 3 回変わるのが見えるように）
    public static let window = 24
    /// 判断を始めるのに必要なフレーム数（約 3 秒）
    public static let minFrames = 12
    /// ルーレットとみなすマス数の上限（これより多く変わるのは、ルーレットではなく盤面の変化）
    public static let maxCells = 8

    /// 止まっているとみなす盤面で、ルーレット以外に変わってよいマス数（実機では読み違いで数マスちらつくことがある）
    public static let noisyCells = 6
    /// 「盤面が止まっている」かを見る直近のフレーム数（約 3 秒。ルートが出たらすぐ動かし始めるので長くは待てない）
    public static let stillWindow = 12
    /// 決まった順（火→水→木→光→闇→回復）に続けて変わった回数がこれ以上なら、盤面が動いていてもルーレット
    public static let orderedSteps = 3

    private var history: [[OrbKind]] = []
    /// 見つけたルーレットのマス
    public private(set) var cells: Set<Int> = []
    /// 診断用：直近の判断材料（マスごとの変化回数・色の種類数、盤面が止まっているとみなしたか）
    public private(set) var lastChanges: [Int] = []
    public private(set) var lastColorCounts: [Int] = []
    public private(set) var lastBoardStill = false

    public init() {}

    public mutating func reset() {
        history.removeAll()
        cells.removeAll()
        lastChanges = []
        lastColorCounts = []
        lastBoardStill = false
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
        // 決まった順に続けて変わったマス：盤面が動いていてもルーレットとみなす
        let ordered = Set((0..<n).filter { Self.orderedRun(cell: $0, in: history) })
        // ルーレットらしいマス：3回以上変わり、色ドロップの3種類以上を行き来している
        // （読み違いのちらつきは、ふつう2種類の間を行き来するだけ）
        let cycling = Set((0..<n).filter { changes[$0] >= 3 && colors[$0].count >= 3 })
        // それ以外のマスは止まっているか（直近約3秒）。読み違いで数マスちらつく程度は許す。
        // ドロップを動かしている最中は、指の通った道に沿って多くのマスが変わる
        let recent = history.suffix(Self.stillWindow)
        var recentChanges = [Int](repeating: 0, count: n)
        for (a, b) in zip(recent.dropLast(), recent.dropFirst()) {
            for i in 0..<n where a[i] != b[i] { recentChanges[i] += 1 }
        }
        let others = (0..<n).filter { !cycling.contains($0) && !ordered.contains($0) && !cells.contains($0) }
        let movedCells = others.filter { recentChanges[$0] > 0 }.count
        let boardStill = movedCells <= Self.noisyCells
        lastChanges = changes
        lastColorCounts = colors.map { $0.count }
        lastBoardStill = boardStill

        var next = cells.union(ordered)
        if boardStill && cycling.count <= Self.maxCells {
            next.formUnion(cycling)
        }
        guard next.count <= Self.maxCells else { return false }
        if !boardStill {   // 動かしている最中：決まった順に変わったマスを足すだけ（外すのは止まっているときだけ）
            let changed = next != cells
            cells = next
            return changed
        }
        // 止まっている盤面で、しばらく変わっていないマスは外す（ルーレットの効果が切れた）
        for i in cells where changes[i] == 0 { next.remove(i) }
        let changed = next != cells
        cells = next
        return changed
    }
}

extension RouletteDetector {
    /// そのマスの色が、決まった順（火→水→木→光→闇→回復）に続けて orderedSteps 回以上変わったか。
    /// 逆の順やバラバラな変化が混ざっていれば（読み違いのちらつき・ドロップの移動）、ルーレットとみなさない
    static func orderedRun(cell i: Int, in frames: [[OrbKind]]) -> Bool {
        var seq: [Int8] = []
        for f in frames {
            let v = f[i].rawValue
            if seq.last != v { seq.append(v) }
        }
        var best = 0, run = 0, right = 0, wrong = 0
        for (a, b) in zip(seq, seq.dropFirst()) {
            if a <= 5 && b <= 5 && b == (a + 1) % 6 {
                run += 1; right += 1; best = max(best, run)
            } else {
                run = 0; wrong += 1
            }
        }
        // 順番どおりに3回以上続けて変わり、順番どおりでない変化（読み違いなど）が少ない
        return best >= orderedSteps && wrong * 2 <= right
    }

    /// 診断用の短い文：変化の多いマス（段・列・変化回数・色の種類数）と、盤面が止まっているとみなしたか
    public func diagnostics(cols: Int) -> String {
        guard !lastChanges.isEmpty else { return "ルーレット判定：まだ判断材料がありません" }
        let busy = lastChanges.indices.filter { lastChanges[$0] > 0 }
            .sorted { lastChanges[$0] > lastChanges[$1] }.prefix(8)
            .map { "\($0 / cols + 1)段\($0 % cols + 1)列×\(lastChanges[$0])(\(lastColorCounts[$0])色)" }
        let found = cells.sorted().map { "\($0 / cols + 1)段\($0 % cols + 1)列" }
        return "ルーレット判定：見つけたマス[\(found.joined(separator: " "))] 盤面停止=\(lastBoardStill ? "はい" : "いいえ") "
            + "変化の多いマス[\(busy.joined(separator: " "))] 直近\(history.count)回分"
    }
}

extension OrbKind {
    /// 火・水・木・光・闇・回復（ルーレットが変わる色）
    var isAttackOrHeart: Bool { rawValue <= 5 }
}

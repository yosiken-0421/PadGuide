import Foundation

/// 敵の妨害（ギミック）による盤面の縛り。アプリで手動で設定し、ルートの計算に反映する。
/// - 操作開始位置の固定：盤面にカーソルが出て、そこからしか動かし始められない
/// - 操作不可（テープ・お札）：そのマスのドロップは動かせず、指で通ることもできない（消すことはできる）
/// - 棘ドロップ：動かすだけでダメージを受けるので、通らないルートにする
/// - 雲・ルーレット：色が見えない／変わり続けるマス。消えないものとして計算する（動かすことはできる）
/// - 消せない状態：指定された種類のドロップは消えない（動かすことはできる）
public struct BoardConstraints: Codable, Equatable, Sendable {
    /// この縛りを設定したときの盤面の大きさ（違う大きさの盤面には使わない）
    public var cols: Int
    public var rows: Int
    public var fixedStart: Int?
    public var blocked: [Int]
    public var thorns: [Int]
    public var hidden: [Int]
    public var unclearable: [OrbKind]

    public init(size: BoardSize, fixedStart: Int? = nil, blocked: [Int] = [], thorns: [Int] = [],
                hidden: [Int] = [], unclearable: [OrbKind] = []) {
        cols = size.cols
        rows = size.rows
        self.fixedStart = fixedStart
        self.blocked = blocked
        self.thorns = thorns
        self.hidden = hidden
        self.unclearable = unclearable
    }

    enum CodingKeys: String, CodingKey { case cols, rows, fixedStart, blocked, thorns, hidden, unclearable }

    /// 項目が増えても古い保存データを読めるように、ない項目は空として読む
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        fixedStart = try c.decodeIfPresent(Int.self, forKey: .fixedStart)
        blocked = try c.decodeIfPresent([Int].self, forKey: .blocked) ?? []
        thorns = try c.decodeIfPresent([Int].self, forKey: .thorns) ?? []
        hidden = try c.decodeIfPresent([Int].self, forKey: .hidden) ?? []
        unclearable = try c.decodeIfPresent([OrbKind].self, forKey: .unclearable) ?? []
    }

    public var size: BoardSize { BoardSize(cols: cols, rows: rows) }

    public var isEmpty: Bool {
        fixedStart == nil && blocked.isEmpty && thorns.isEmpty && hidden.isEmpty && unclearable.isEmpty
    }

    public func applies(to s: BoardSize) -> Bool { s.cols == cols && s.rows == rows }

    /// この盤面で使う縛り。マスを指定する縛りは同じ大きさの盤面だけに使い、「消せない色」は大きさによらず使う。
    /// 何も残らなければ nil
    public func effective(for s: BoardSize) -> BoardConstraints? {
        let c = applies(to: s) ? self : BoardConstraints(size: s, unclearable: unclearable)
        return c.isEmpty ? nil : c
    }

    /// 手動の縛りに、画面から自動で見つけた操作不可（テープ）のマスを足した縛り（手動の設定そのものは変えない）
    public static func merging(_ base: BoardConstraints?, autoBlocked: [Int], size: BoardSize) -> BoardConstraints? {
        let add = autoBlocked.filter { $0 >= 0 && $0 < size.count }
        guard !add.isEmpty else { return base }
        var c = base?.effective(for: size) ?? BoardConstraints(size: size)
        for i in add.sorted() where !c.blocked.contains(i) && c.fixedStart != i {
            c.thorns.removeAll { $0 == i }
            c.blocked.append(i)
        }
        return c
    }

    /// 指で通れるマスか（操作不可・棘は通らない）
    public func canEnter(_ i: Int) -> Bool { !blocked.contains(i) && !thorns.contains(i) }

    /// 動かし始めてよいマス
    public func startCells() -> [Int] {
        let n = cols * rows
        if let s = fixedStart, s >= 0, s < n { return [s] }
        return (0..<n).filter { canEnter($0) }
    }

    /// 計算用の盤面：雲・ルーレットのマスと、消せない種類のドロップは「消えないドロップ」として扱う
    public func solvingBoard(_ b: Board) -> Board {
        guard let c = effective(for: b.size) else { return b }
        var out = b
        let hidden = c.hidden
        for i in hidden where i >= 0 && i < out.cells.count { out.cells[i] = .unknown }
        if !unclearable.isEmpty {
            for i in out.cells.indices where unclearable.contains(out.cells[i]) { out.cells[i] = .unknown }
        }
        return out
    }

    /// ルートが縛りを守っているか（テスト・確認用）
    public func allows(path: [Int]) -> Bool {
        guard let first = path.first else { return true }
        if let s = fixedStart, first != s { return false }
        if fixedStart == nil && !canEnter(first) { return false }
        return path.dropFirst().allSatisfy { canEnter($0) }
    }

    /// マスの縛りの種類（表示用）
    public enum CellMark: String, Sendable { case start = "開始", blocked = "不可", thorn = "棘", hidden = "雲" }

    public func mark(_ i: Int) -> CellMark? {
        if fixedStart == i { return .start }
        if blocked.contains(i) { return .blocked }
        if thorns.contains(i) { return .thorn }
        if hidden.contains(i) { return .hidden }
        return nil
    }

    /// マスごとの縛りを切り替える（同じマスの別の縛りは外す）
    public mutating func toggle(_ m: CellMark, at i: Int) {
        let had = mark(i) == m
        if fixedStart == i { fixedStart = nil }
        blocked.removeAll { $0 == i }
        thorns.removeAll { $0 == i }
        hidden.removeAll { $0 == i }
        guard !had else { return }
        switch m {
        case .start: fixedStart = i
        case .blocked: blocked.append(i)
        case .thorn: thorns.append(i)
        case .hidden: hidden.append(i)
        }
    }

    /// 設定内容の短い説明（表示用）
    public var summary: String {
        var a: [String] = []
        if let s = fixedStart { a.append("開始位置固定（上から\(s / cols + 1)段目・左から\(s % cols + 1)列目）") }
        if !blocked.isEmpty { a.append("操作不可 \(blocked.count)マス") }
        if !thorns.isEmpty { a.append("棘 \(thorns.count)マス") }
        if !hidden.isEmpty { a.append("雲・ルーレット \(hidden.count)マス") }
        if !unclearable.isEmpty { a.append("消せない：" + unclearable.map { $0.label }.joined(separator: "・")) }
        return a.isEmpty ? "なし" : a.joined(separator: "、")
    }
}

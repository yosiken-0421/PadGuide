import Foundation

/// 自動で見つけた操作不可（テープ）のマスを、フレームごとのちらつきに左右されないように保つ。
/// - 新しく貼られたテープは 2 フレーム続けて見えたら使う
/// - 消えたとみなすのは、約 3 秒（12 フレーム）続けて見えなかったときだけ
///   （ドロップを持って帯の上を通ると、帯が一時的に見つからなくなることがあるため）
public struct TapeTracker: Sendable {
    public static let addFrames = 2
    public static let removeFrames = 12

    public private(set) var cells: Set<Int> = []
    private var pending: Set<Int>?
    private var pendingCount = 0

    public init() {}

    public mutating func reset() {
        cells.removeAll(); pending = nil; pendingCount = 0
    }

    /// 1 フレーム分の結果を渡す。使うマスが変わったら true
    @discardableResult
    public mutating func feed(_ seen: Set<Int>) -> Bool {
        if seen == cells { pending = nil; pendingCount = 0; return false }
        if pending == seen { pendingCount += 1 } else { pending = seen; pendingCount = 1 }
        let need = seen.isSuperset(of: cells) ? Self.addFrames : Self.removeFrames
        guard pendingCount >= need else { return false }
        cells = seen
        pending = nil
        pendingCount = 0
        return true
    }
}

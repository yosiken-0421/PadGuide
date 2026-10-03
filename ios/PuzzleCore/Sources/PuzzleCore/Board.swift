import Foundation

/// ドロップの種類。rawValue は通信・保存用の固定値なので変更しないこと。
public enum OrbKind: Int8, CaseIterable, Codable, Sendable {
    case fire = 0, water = 1, wood = 2, light = 3, dark = 4, heart = 5
    case jammer = 6, poison = 7, mortalPoison = 8
    case unknown = 9

    /// 日本語の短い表示名
    public var label: String {
        switch self {
        case .fire: return "火"
        case .water: return "水"
        case .wood: return "木"
        case .light: return "光"
        case .dark: return "闇"
        case .heart: return "回復"
        case .jammer: return "お邪魔"
        case .poison: return "毒"
        case .mortalPoison: return "猛毒"
        case .unknown: return "不明"
        }
    }

    /// 通信用のキー（PC ビューアーと共通）
    public var key: String {
        switch self {
        case .fire: return "fire"
        case .water: return "water"
        case .wood: return "wood"
        case .light: return "light"
        case .dark: return "dark"
        case .heart: return "heart"
        case .jammer: return "jammer"
        case .poison: return "poison"
        case .mortalPoison: return "mortal"
        case .unknown: return "unknown"
        }
    }

    public init?(key: String) {
        guard let k = OrbKind.allCases.first(where: { $0.key == key }) else { return nil }
        self = k
    }

    /// 3個並べて消せる種類か（不明は消えない扱い）
    public var isMatchable: Bool { self != .unknown }

    /// 5色同時消しの対象（火水木光闇）
    public var isAttackColor: Bool { rawValue <= 4 }
}

public struct BoardSize: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }

    public static let sixByFive = BoardSize(cols: 6, rows: 5)
    public static let sevenBySix = BoardSize(cols: 7, rows: 6)
    public static let fiveByFour = BoardSize(cols: 5, rows: 4)
    /// 自動判定で試すサイズ
    public static let supported: [BoardSize] = [.sixByFive, .sevenBySix, .fiveByFour]

    public var count: Int { cols * rows }
    public var description: String { "\(cols)×\(rows)" }
}

/// 盤面（左上から行ごとに並べたドロップ）
public struct Board: Codable, Equatable, Sendable {
    public let size: BoardSize
    public var cells: [OrbKind]

    public init(size: BoardSize, cells: [OrbKind]) {
        precondition(cells.count == size.count, "マス数が盤面サイズと一致しません")
        self.size = size
        self.cells = cells
    }

    /// "RBGLDH" のような文字列から作る（テスト・デバッグ用）。
    /// R=火 B=水 G=木 L=光 D=闇 H=回復 J=お邪魔 P=毒 M=猛毒 ?=不明。空白・改行は無視。
    public init(size: BoardSize, string: String) {
        let map: [Character: OrbKind] = ["R": .fire, "B": .water, "G": .wood, "L": .light, "D": .dark,
                                         "H": .heart, "J": .jammer, "P": .poison, "M": .mortalPoison, "?": .unknown]
        let cs = string.compactMap { map[$0] }
        self.init(size: size, cells: cs)
    }

    public subscript(row: Int, col: Int) -> OrbKind {
        get { cells[row * size.cols + col] }
        set { cells[row * size.cols + col] = newValue }
    }

    public var raw: [Int8] { cells.map { $0.rawValue } }

    public var unknownCount: Int { cells.filter { $0 == .unknown }.count }
}

/// 移動方向（斜めは使わない）
public enum Direction: String, Codable, CaseIterable, Sendable {
    case up = "U", down = "D", left = "L", right = "R"

    public var delta: (dr: Int, dc: Int) {
        switch self {
        case .up: return (-1, 0)
        case .down: return (1, 0)
        case .left: return (0, -1)
        case .right: return (0, 1)
        }
    }

    public var arrow: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }
}

public enum BoardOps {
    /// pos から dir へ1マス動かした先。盤面外なら nil（＝その移動は拒否）
    public static func neighbor(_ pos: Int, _ dir: Direction, _ size: BoardSize) -> Int? {
        let r = pos / size.cols + dir.delta.dr
        let c = pos % size.cols + dir.delta.dc
        guard r >= 0, r < size.rows, c >= 0, c < size.cols else { return nil }
        return r * size.cols + c
    }

    /// 手で動かした結果の盤面。盤面外へ出る移動があれば nil
    public static func apply(start: Int, moves: [Direction], to board: Board) -> Board? {
        guard start >= 0, start < board.size.count else { return nil }
        var b = board
        var pos = start
        for m in moves {
            guard let np = neighbor(pos, m, board.size) else { return nil }
            b.cells.swapAt(pos, np)
            pos = np
        }
        return b
    }
}

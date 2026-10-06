import Foundation

public enum LedgerEntryType: String, Codable, CaseIterable, Identifiable, Sendable {
    case expense
    case income
    public var id: String { rawValue }
    public var label: String { self == .expense ? "支出" : "収入" }
}

public enum LedgerCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, daily, transport, housing, medical, leisure, salary, other
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .food: "食費"
        case .daily: "日用品"
        case .transport: "交通"
        case .housing: "住居"
        case .medical: "医療"
        case .leisure: "娯楽"
        case .salary: "給与"
        case .other: "その他"
        }
    }

    public static func choices(for type: LedgerEntryType) -> [LedgerCategory] {
        type == .income ? [.salary, .other] : [.food, .daily, .transport, .housing, .medical, .leisure, .other]
    }
}

public struct LedgerEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var type: LedgerEntryType
    public var category: LedgerCategory
    public var amount: Int
    public var memo: String

    public init(id: UUID = UUID(), date: Date = Date(), type: LedgerEntryType, category: LedgerCategory, amount: Int, memo: String = "") {
        self.id = id
        self.date = date
        self.type = type
        self.category = category
        self.amount = max(0, amount)
        self.memo = memo
    }
}

public struct LedgerSummary: Equatable, Sendable {
    public var income: Int
    public var expense: Int
    public var balance: Int { income - expense }
    public init(income: Int, expense: Int) {
        self.income = income
        self.expense = expense
    }
}

public enum LedgerCalculator {
    public static func monthlySummary(entries: [LedgerEntry], monthContaining date: Date, calendar: Calendar = .current) -> LedgerSummary {
        guard let interval = calendar.dateInterval(of: .month, for: date) else {
            return LedgerSummary(income: 0, expense: 0)
        }
        var income = 0
        var expense = 0
        for entry in entries where interval.contains(entry.date) {
            if entry.type == .income { income += entry.amount } else { expense += entry.amount }
        }
        return LedgerSummary(income: income, expense: expense)
    }

    public static func filtered(entries: [LedgerEntry], query: String) -> [LedgerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.memo.localizedCaseInsensitiveContains(q)
            || $0.category.label.localizedCaseInsensitiveContains(q)
            || $0.type.label.localizedCaseInsensitiveContains(q)
        }
    }
}

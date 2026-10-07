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

public struct CategoryTotal: Identifiable, Equatable, Sendable {
    public var category: LedgerCategory
    public var amount: Int
    public var id: String { category.rawValue }

    public init(category: LedgerCategory, amount: Int) {
        self.category = category
        self.amount = amount
    }
}

public struct MonthTotal: Identifiable, Equatable, Sendable {
    public var month: Date
    public var expense: Int
    public var id: Date { month }

    public init(month: Date, expense: Int) {
        self.month = month
        self.expense = expense
    }
}

public enum LedgerCalculator {
    public static func entries(inMonthContaining date: Date, from entries: [LedgerEntry], calendar: Calendar = .current) -> [LedgerEntry] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return entries.filter { interval.contains($0.date) }
    }

    public static func monthlySummary(entries: [LedgerEntry], monthContaining date: Date, calendar: Calendar = .current) -> LedgerSummary {
        let monthEntries = LedgerCalculator.entries(inMonthContaining: date, from: entries, calendar: calendar)
        var income = 0
        var expense = 0
        for entry in monthEntries {
            if entry.type == .income { income += entry.amount } else { expense += entry.amount }
        }
        return LedgerSummary(income: income, expense: expense)
    }

    public static func expenseByCategory(entries: [LedgerEntry], monthContaining date: Date, calendar: Calendar = .current) -> [CategoryTotal] {
        let monthEntries = LedgerCalculator.entries(inMonthContaining: date, from: entries, calendar: calendar)
            .filter { $0.type == .expense }
        var totals: [LedgerCategory: Int] = [:]
        for entry in monthEntries {
            totals[entry.category, default: 0] += entry.amount
        }
        return totals
            .map { CategoryTotal(category: $0.key, amount: $0.value) }
            .sorted {
                if $0.amount == $1.amount { return $0.category.rawValue < $1.category.rawValue }
                return $0.amount > $1.amount
            }
    }

    public static func recentMonthlyExpenses(entries: [LedgerEntry], endingAt date: Date, count: Int, calendar: Calendar = .current) -> [MonthTotal] {
        guard count > 0 else { return [] }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return (0..<count).reversed().compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: -offset, to: monthStart) else { return nil }
            let summary = monthlySummary(entries: entries, monthContaining: month, calendar: calendar)
            return MonthTotal(month: month, expense: summary.expense)
        }
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

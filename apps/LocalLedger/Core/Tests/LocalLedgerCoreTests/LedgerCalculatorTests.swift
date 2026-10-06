import XCTest
@testable import LocalLedgerCore

final class LedgerCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testMonthlySummarySeparatesIncomeAndExpense() {
        let entries = [
            LedgerEntry(date: date(2026,10,1), type: .income, category: .salary, amount: 200_000),
            LedgerEntry(date: date(2026,10,2), type: .expense, category: .food, amount: 3_500),
            LedgerEntry(date: date(2026,10,3), type: .expense, category: .transport, amount: 1_200),
            LedgerEntry(date: date(2026,9,30), type: .expense, category: .food, amount: 999)
        ]
        let result = LedgerCalculator.monthlySummary(entries: entries, monthContaining: date(2026,10,15), calendar: calendar)
        XCTAssertEqual(result.income, 200_000)
        XCTAssertEqual(result.expense, 4_700)
        XCTAssertEqual(result.balance, 195_300)
    }

    func testCategoryTotalsAreSortedByAmount() {
        let entries = [
            LedgerEntry(date: date(2026,10,1), type: .expense, category: .food, amount: 1_000),
            LedgerEntry(date: date(2026,10,2), type: .expense, category: .food, amount: 500),
            LedgerEntry(date: date(2026,10,3), type: .expense, category: .transport, amount: 2_000),
            LedgerEntry(date: date(2026,10,4), type: .income, category: .salary, amount: 50_000)
        ]
        let totals = LedgerCalculator.expenseByCategory(entries: entries, monthContaining: date(2026,10,20), calendar: calendar)
        XCTAssertEqual(totals, [
            CategoryTotal(category: .transport, amount: 2_000),
            CategoryTotal(category: .food, amount: 1_500)
        ])
    }

    func testRecentMonthlyExpensesIncludesEmptyMonths() {
        let entries = [
            LedgerEntry(date: date(2026,8,3), type: .expense, category: .food, amount: 800),
            LedgerEntry(date: date(2026,10,3), type: .expense, category: .food, amount: 1_000)
        ]
        let points = LedgerCalculator.recentMonthlyExpenses(entries: entries, endingAt: date(2026,10,9), count: 3, calendar: calendar)
        XCTAssertEqual(points.map(\.expense), [800, 0, 1_000])
    }

    func testSearchMatchesMemoCategoryAndType() {
        let entries = [
            LedgerEntry(type: .expense, category: .food, amount: 900, memo: "スーパー"),
            LedgerEntry(type: .income, category: .salary, amount: 100_000, memo: "10月分")
        ]
        XCTAssertEqual(LedgerCalculator.filtered(entries: entries, query: "スーパー").count, 1)
        XCTAssertEqual(LedgerCalculator.filtered(entries: entries, query: "給与").count, 1)
        XCTAssertEqual(LedgerCalculator.filtered(entries: entries, query: "支出").count, 1)
        XCTAssertEqual(LedgerCalculator.filtered(entries: entries, query: "").count, 2)
    }

    func testNegativeAmountIsClampedToZero() {
        let entry = LedgerEntry(type: .expense, category: .other, amount: -100)
        XCTAssertEqual(entry.amount, 0)
    }
}

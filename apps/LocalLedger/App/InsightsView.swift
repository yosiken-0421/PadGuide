import SwiftUI
import Charts
import LocalLedgerCore

struct InsightsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var selectedMonth = Date()

    private var summary: LedgerSummary {
        LedgerCalculator.monthlySummary(entries: store.entries, monthContaining: selectedMonth)
    }

    private var categories: [CategoryTotal] {
        LedgerCalculator.expenseByCategory(entries: store.entries, monthContaining: selectedMonth)
    }

    private var trend: [MonthTotal] {
        LedgerCalculator.recentMonthlyExpenses(entries: store.entries, endingAt: selectedMonth, count: 6)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button {
                            selectedMonth = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        Spacer()
                        Text(selectedMonth, format: .dateTime.year().month())
                            .font(.headline)
                        Spacer()
                        Button {
                            let next = Calendar.current.date(byAdding: .month, value: 1, to: selectedMonth) ?? selectedMonth
                            if next <= Date() { selectedMonth = next }
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month))
                    }
                }

                Section("6か月の支出") {
                    if trend.allSatisfy({ $0.expense == 0 }) {
                        Text("支出を記録すると、ここに月ごとの推移が表示されます。")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(trend) { point in
                            BarMark(
                                x: .value("月", point.month, unit: .month),
                                y: .value("支出", point.expense)
                            )
                        }
                        .frame(height: 180)
                        .accessibilityLabel("直近6か月の支出推移")
                    }
                }

                Section("カテゴリ別支出") {
                    if categories.isEmpty {
                        Text("この月の支出はまだありません。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(categories) { item in
                            HStack {
                                Text(item.category.label)
                                Spacer()
                                Text(item.amount, format: .currency(code: "JPY").precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section("今月のまとめ") {
                    LabeledContent("収入", value: summary.income, format: .currency(code: "JPY").precision(.fractionLength(0)))
                    LabeledContent("支出", value: summary.expense, format: .currency(code: "JPY").precision(.fractionLength(0)))
                    LabeledContent("残高", value: summary.balance, format: .currency(code: "JPY").precision(.fractionLength(0)))
                }
            }
            .navigationTitle("分析")
        }
    }
}

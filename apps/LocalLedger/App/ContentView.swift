import SwiftUI
import LocalLedgerCore

private enum RootTab: Hashable {
    case records
    case insights
    case settings
}

struct ContentView: View {
    @State private var selectedTab: RootTab

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let initial: RootTab
        if arguments.contains("--analysis-tab") {
            initial = .insights
        } else if arguments.contains("--settings-tab") {
            initial = .settings
        } else {
            initial = .records
        }
        _selectedTab = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordsView()
                .tabItem { Label("記録", systemImage: "list.bullet.rectangle") }
                .tag(RootTab.records)

            InsightsView()
                .tabItem { Label("分析", systemImage: "chart.bar") }
                .tag(RootTab.insights)

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .accessibilityIdentifier("ledgerRoot")
    }
}

private struct RecordsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var showingAdd = false
    @State private var showingDeleteAll = false
    @State private var editingEntry: LedgerEntry?
    @State private var query = ""
    @State private var selectedMonth = Date()

    private var summary: LedgerSummary {
        LedgerCalculator.monthlySummary(entries: store.entries, monthContaining: selectedMonth)
    }

    private var monthEntries: [LedgerEntry] {
        LedgerCalculator.entries(inMonthContaining: selectedMonth, from: store.entries)
    }

    private var visibleEntries: [LedgerEntry] {
        LedgerCalculator.filtered(entries: monthEntries, query: query).sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MonthPicker(selectedMonth: $selectedMonth)

                    SummaryView(summary: summary)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    if let budget = store.monthlyBudget {
                        BudgetProgressView(budget: budget, expense: summary.expense)
                    }
                }

                Section("記録") {
                    if visibleEntries.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "この月の記録はありません" : "一致する記録がありません",
                            systemImage: query.isEmpty ? "calendar.badge.plus" : "magnifyingglass",
                            description: Text(query.isEmpty ? "右上の＋から収支を追加できます。" : "検索条件を変えてください。")
                        )
                    } else {
                        ForEach(visibleEntries) { entry in
                            Button {
                                editingEntry = entry
                            } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("削除", role: .destructive) {
                                    store.delete(ids: [entry.id])
                                }
                            }
                        }
                    }
                }

                if !store.entries.isEmpty {
                    Section {
                        Button("すべての記録を削除", role: .destructive) { showingDeleteAll = true }
                    } footer: {
                        Text("データはこのiPhone内だけに保存されます。広告・解析・外部送信はありません。")
                    }
                }
            }
            .navigationTitle("まいにち家計簿")
            .searchable(text: $query, prompt: "メモ・カテゴリを検索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Label("追加", systemImage: "plus") }
                        .accessibilityIdentifier("addEntryButton")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddEntryView().environmentObject(store)
            }
            .sheet(item: $editingEntry) { entry in
                AddEntryView(entry: entry).environmentObject(store)
            }
            .confirmationDialog("すべての記録を削除しますか？", isPresented: $showingDeleteAll, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { store.deleteAll() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この操作は取り消せません。")
            }
        }
    }
}

private struct MonthPicker: View {
    @Binding var selectedMonth: Date

    var body: some View {
        HStack {
            Button {
                selectedMonth = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("前の月")

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
            .accessibilityLabel("次の月")
            .disabled(Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month))
        }
    }
}

private struct SummaryView: View {
    let summary: LedgerSummary

    var body: some View {
        HStack(spacing: 10) {
            SummaryCell(title: "収入", value: summary.income)
            SummaryCell(title: "支出", value: summary.expense)
            SummaryCell(title: "残高", value: summary.balance)
        }
        .padding(.vertical, 8)
    }
}

private struct SummaryCell: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value, format: .currency(code: "JPY").precision(.fractionLength(0)))
                .font(.headline)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct BudgetProgressView: View {
    let budget: Int
    let expense: Int

    private var remaining: Int { max(0, budget - expense) }
    private var progress: Double {
        guard budget > 0 else { return 0 }
        return min(1, Double(expense) / Double(budget))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("月予算")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("残り \(remaining.formatted(.currency(code: "JPY").precision(.fractionLength(0))))")
                    .font(.subheadline)
            }

            ProgressView(value: progress)

            Text("予算 \(budget.formatted(.currency(code: "JPY").precision(.fractionLength(0)))) / 使用 \(expense.formatted(.currency(code: "JPY").precision(.fractionLength(0))))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EntryRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.category.label)
                    .font(.headline)

                if !entry.memo.isEmpty {
                    Text(entry.memo)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.date, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.type == .expense ? -entry.amount : entry.amount,
                 format: .currency(code: "JPY").precision(.fractionLength(0)))
                .font(.headline)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("タップして編集")
    }
}

import SwiftUI
import LocalLedgerCore

struct ContentView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var showingAdd = false
    @State private var showingDeleteAll = false
    @State private var query = ""

    private var summary: LedgerSummary {
        LedgerCalculator.monthlySummary(entries: store.entries, monthContaining: Date())
    }

    private var visibleEntries: [LedgerEntry] {
        LedgerCalculator.filtered(entries: store.entries, query: query).sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SummaryView(summary: summary)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("記録") {
                    if visibleEntries.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "まだ記録がありません" : "一致する記録がありません",
                            systemImage: query.isEmpty ? "yensign.circle" : "magnifyingglass",
                            description: Text(query.isEmpty ? "右上の＋から最初の収支を追加できます。" : "検索条件を変えてください。")
                        )
                    } else {
                        ForEach(visibleEntries) { entry in
                            EntryRow(entry: entry)
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { index in
                                visibleEntries.indices.contains(index) ? visibleEntries[index].id : nil
                            })
                            store.delete(ids: ids)
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
            .accessibilityIdentifier("ledgerRoot")
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
            .confirmationDialog("すべての記録を削除しますか？", isPresented: $showingDeleteAll, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { store.deleteAll() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この操作は取り消せません。")
            }
        }
    }
}

private struct SummaryView: View {
    let summary: LedgerSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今月").font(.headline)
            HStack(spacing: 12) {
                SummaryCell(title: "収入", value: summary.income)
                SummaryCell(title: "支出", value: summary.expense)
                SummaryCell(title: "残高", value: summary.balance)
            }
        }.padding(.vertical, 8)
    }
}

private struct SummaryCell: View {
    let title: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "JPY").precision(.fractionLength(0)))
                .font(.headline).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct EntryRow: View {
    let entry: LedgerEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.category.label).font(.headline)
                if !entry.memo.isEmpty {
                    Text(entry.memo).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(entry.date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.type == .expense ? -entry.amount : entry.amount,
                 format: .currency(code: "JPY").precision(.fractionLength(0)))
                .font(.headline)
        }.accessibilityElement(children: .combine)
    }
}

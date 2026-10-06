import SwiftUI
import LocalLedgerCore

struct AddEntryView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var type: LedgerEntryType = .expense
    @State private var category: LedgerCategory = .food
    @State private var amountText = ""
    @State private var memo = ""
    @State private var date = Date()

    private var amount: Int? { Int(amountText.replacingOccurrences(of: ",", with: "")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種類", selection: $type) {
                        ForEach(LedgerEntryType.allCases) { item in Text(item.label).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: type) { _, newValue in
                        category = LedgerCategory.choices(for: newValue).first ?? .other
                    }

                    TextField("金額", text: $amountText).keyboardType(.numberPad)

                    Picker("カテゴリ", selection: $category) {
                        ForEach(LedgerCategory.choices(for: type)) { item in Text(item.label).tag(item) }
                    }

                    DatePicker("日付", selection: $date, displayedComponents: .date)
                    TextField("メモ（任意）", text: $memo)
                }
            }
            .navigationTitle("収支を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let amount, amount > 0 else { return }
                        store.add(LedgerEntry(
                            date: date, type: type, category: category, amount: amount,
                            memo: memo.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        dismiss()
                    }
                    .disabled((amount ?? 0) <= 0)
                    .accessibilityIdentifier("saveEntryButton")
                }
            }
        }
    }
}

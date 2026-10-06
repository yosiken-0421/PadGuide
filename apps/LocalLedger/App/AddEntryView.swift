import SwiftUI
import LocalLedgerCore

struct AddEntryView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    private let editingID: UUID?

    @State private var type: LedgerEntryType
    @State private var category: LedgerCategory
    @State private var amountText: String
    @State private var memo: String
    @State private var date: Date

    init(entry: LedgerEntry? = nil) {
        editingID = entry?.id
        _type = State(initialValue: entry?.type ?? .expense)
        _category = State(initialValue: entry?.category ?? .food)
        _amountText = State(initialValue: entry.map { String($0.amount) } ?? "")
        _memo = State(initialValue: entry?.memo ?? "")
        _date = State(initialValue: entry?.date ?? Date())
    }

    private var amount: Int? {
        Int(amountText.replacingOccurrences(of: ",", with: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種類", selection: $type) {
                        ForEach(LedgerEntryType.allCases) { item in Text(item.label).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: type) { _, newValue in
                        if !LedgerCategory.choices(for: newValue).contains(category) {
                            category = LedgerCategory.choices(for: newValue).first ?? .other
                        }
                    }

                    TextField("金額", text: $amountText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("amountField")

                    Picker("カテゴリ", selection: $category) {
                        ForEach(LedgerCategory.choices(for: type)) { item in Text(item.label).tag(item) }
                    }

                    DatePicker("日付", selection: $date, displayedComponents: .date)

                    TextField("メモ（任意）", text: $memo)
                        .accessibilityIdentifier("memoField")
                }
            }
            .navigationTitle(editingID == nil ? "収支を追加" : "収支を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let amount, amount > 0 else { return }
                        let entry = LedgerEntry(
                            id: editingID ?? UUID(),
                            date: date,
                            type: type,
                            category: category,
                            amount: amount,
                            memo: memo.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        if editingID == nil {
                            store.add(entry)
                        } else {
                            store.update(entry)
                        }
                        dismiss()
                    }
                    .disabled((amount ?? 0) <= 0)
                    .accessibilityIdentifier("saveEntryButton")
                }
            }
        }
    }
}

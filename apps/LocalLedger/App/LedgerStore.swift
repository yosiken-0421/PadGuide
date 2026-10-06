import Foundation
import LocalLedgerCore

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var entries: [LedgerEntry] = []
    @Published private(set) var monthlyBudget: Int?

    private struct StoredLedger: Codable {
        var entries: [LedgerEntry]
        var monthlyBudget: Int?
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("LocalLedger", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("ledger.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-data") {
            loadDemoData()
        }
        #endif
    }

    func add(_ entry: LedgerEntry) {
        entries.append(entry)
        sortEntries()
        save()
    }

    func update(_ entry: LedgerEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        sortEntries()
        save()
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAll() {
        entries.removeAll()
        save()
    }

    func setMonthlyBudget(_ amount: Int?) {
        if let amount, amount > 0 {
            monthlyBudget = amount
        } else {
            monthlyBudget = nil
        }
        save()
    }

    private func sortEntries() {
        entries.sort {
            if $0.date == $1.date { return $0.id.uuidString < $1.id.uuidString }
            return $0.date > $1.date
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            monthlyBudget = nil
            return
        }

        if let decoded = try? decoder.decode(StoredLedger.self, from: data) {
            entries = decoded.entries
            monthlyBudget = decoded.monthlyBudget
            sortEntries()
            return
        }

        // v1初期形式（配列のみ）からの移行用。
        if let legacy = try? decoder.decode([LedgerEntry].self, from: data) {
            entries = legacy
            monthlyBudget = nil
            sortEntries()
            save()
            return
        }

        entries = []
        monthlyBudget = nil
    }

    #if DEBUG
    private func loadDemoData() {
        let calendar = Calendar.current

        func date(monthOffset: Int, day: Int) -> Date {
            let shifted = calendar.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
            var components = calendar.dateComponents([.year, .month], from: shifted)
            components.day = day
            components.hour = 12
            return calendar.date(from: components) ?? shifted
        }

        entries = [
            LedgerEntry(date: date(monthOffset: 0, day: 25), type: .income, category: .salary, amount: 280_000, memo: "給与"),
            LedgerEntry(date: date(monthOffset: 0, day: 24), type: .expense, category: .housing, amount: 68_000, memo: "家賃"),
            LedgerEntry(date: date(monthOffset: 0, day: 20), type: .expense, category: .food, amount: 4_860, memo: "スーパー"),
            LedgerEntry(date: date(monthOffset: 0, day: 18), type: .expense, category: .transport, amount: 3_200, memo: "交通費"),
            LedgerEntry(date: date(monthOffset: 0, day: 12), type: .expense, category: .daily, amount: 2_480, memo: "日用品"),
            LedgerEntry(date: date(monthOffset: 0, day: 8), type: .expense, category: .leisure, amount: 5_500, memo: "休日"),
            LedgerEntry(date: date(monthOffset: -1, day: 18), type: .expense, category: .food, amount: 31_400, memo: "食費"),
            LedgerEntry(date: date(monthOffset: -1, day: 10), type: .expense, category: .housing, amount: 68_000, memo: "家賃"),
            LedgerEntry(date: date(monthOffset: -2, day: 18), type: .expense, category: .food, amount: 29_700, memo: "食費"),
            LedgerEntry(date: date(monthOffset: -2, day: 10), type: .expense, category: .housing, amount: 68_000, memo: "家賃"),
            LedgerEntry(date: date(monthOffset: -3, day: 18), type: .expense, category: .food, amount: 34_100, memo: "食費"),
            LedgerEntry(date: date(monthOffset: -3, day: 10), type: .expense, category: .housing, amount: 68_000, memo: "家賃"),
            LedgerEntry(date: date(monthOffset: -4, day: 18), type: .expense, category: .food, amount: 27_800, memo: "食費"),
            LedgerEntry(date: date(monthOffset: -4, day: 10), type: .expense, category: .housing, amount: 68_000, memo: "家賃"),
            LedgerEntry(date: date(monthOffset: -5, day: 18), type: .expense, category: .food, amount: 30_900, memo: "食費"),
            LedgerEntry(date: date(monthOffset: -5, day: 10), type: .expense, category: .housing, amount: 68_000, memo: "家賃")
        ]
        monthlyBudget = 100_000
        sortEntries()
    }
    #endif

    private func save() {
        let payload = StoredLedger(entries: entries, monthlyBudget: monthlyBudget)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

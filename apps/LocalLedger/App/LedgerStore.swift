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

    private func save() {
        let payload = StoredLedger(entries: entries, monthlyBudget: monthlyBudget)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

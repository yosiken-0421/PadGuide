import Foundation
import LocalLedgerCore

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var entries: [LedgerEntry] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("LocalLedger", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("entries.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func add(_ entry: LedgerEntry) {
        entries.append(entry)
        entries.sort { $0.date > $1.date }
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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([LedgerEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.date > $1.date }
    }

    private func save() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

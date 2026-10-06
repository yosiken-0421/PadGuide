import SwiftUI

@main
struct LocalLedgerApp: App {
    @StateObject private var store = LedgerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

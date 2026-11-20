import SwiftUI

@main
struct WristDictationApp: App {
    @StateObject private var store = IOSStore()

    var body: some Scene {
        WindowGroup {
            LibraryListView()
                .environmentObject(store)
                .onAppear {
                    PhoneRemoteBridge.shared.refresh()
                    store.refreshSessionState()
                    store.autoSyncIfNeeded()
                }
        }
    }
}

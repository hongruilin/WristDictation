import SwiftUI
import Combine

@main
struct WristDictationWatchApp: App {
    @StateObject private var store = WatchStore()
    @StateObject private var engine = DictationEngine()
    @StateObject private var coordinator = WatchCoordinator()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(coordinator)
                .onAppear {
                    coordinator.bind(store: store, engine: engine)
                }
        }
    }
}

/// 把同步、会话恢复、命令转发串起来，让视图层只关心展示。
final class WatchCoordinator: ObservableObject {

    @Published var recoverable: SessionSnapshot?
    @Published var lastSyncMessage: String?

    private weak var store: WatchStore?
    private weak var engine: DictationEngine?

    func bind(store: WatchStore, engine: DictationEngine) {
        guard self.store == nil else { return }
        self.store = store
        self.engine = engine
        self.recoverable = PlaybackStateStore.shared.loadRecoverable()

        let sync = WatchSyncManager.shared
        sync.voiceProvider = { SystemSpeechService.availableSystemVoices() }
        sync.stateProvider = { [weak store] in
            store?.stateReport() ?? .empty
        }
        sync.onPayload = { [weak self] payload, version in
            guard let store = self?.store else { return }
            // 幂等判断已由 WatchSyncManager 统一做过（版本不比本地新时不会回调这里），
            // 所以这里只管落盘。回执也不再单独发——调用方的回包里已经带了状态和语音。
            do {
                try store.apply(payload, version: version)
                self?.lastSyncMessage = "已同步 \(payload.libraries.count) 个词库"
                self?.recoverable = PlaybackStateStore.shared.loadRecoverable()
            } catch {
                self?.lastSyncMessage = error.localizedDescription
                AppLog.log("watch.apply failed: \(error.localizedDescription)")
            }
        }
        sync.onCommand = { [weak self] command in
            self?.handle(command)
        }
        sync.activate()
    }

    /// iPhone 转发来的命令（耳机连手机时的兜底通道）
    private func handle(_ command: String) {
        guard let engine else { return }
        switch command {
        case "play": engine.resume()
        case "pause": engine.pause()
        case "toggle": engine.togglePlayPause()
        case "next": engine.next()
        case "previous": engine.previous()
        default: break
        }
    }

    func start(_ library: WordLibrary, settings: AppSettings, resume snapshot: SessionSnapshot?) {
        recoverable = nil
        engine?.start(library: library, settings: settings, resume: snapshot)
    }

    /// 重新读一次磁盘上的快照。
    ///
    /// **必须由视图在"回到首页"时主动调**：`recoverable` 原本只在 `bind()`
    /// （App 启动）和收到同步包时赋值，而 `start()` 会把它置 nil。
    /// 于是"播了几组 → 返回首页"这条最常见的路径上，首页拿到的永远是 nil，
    /// 用户看到的就是"没有中断记录、只能从头再来"。
    func refreshRecoverable() {
        let snapshot = PlaybackStateStore.shared.loadRecoverable()
        if snapshot?.updatedAt != recoverable?.updatedAt {
            recoverable = snapshot
        }
    }

    func discardRecovery() {
        PlaybackStateStore.shared.clear()
        recoverable = nil
    }
}

import Foundation

/// 一次听写会话的可恢复快照。
/// watchOS 会随时挂起甚至终止 App，所以每次状态迁移都要落盘。
struct SessionSnapshot: Codable {
    var libraryID: UUID
    var libraryName: String
    var mode: PlaybackMode
    /// 保存队列的词条 ID 而非文本，避免与词库不同步时数据漂移。
    var queueEntryIDs: [UUID]
    var currentIndex: Int
    var currentRepeat: Int
    var phaseRaw: String
    var remainingSeconds: Double?
    var playedItems: [PlayedItem]
    var startedAt: Date
    var updatedAt: Date
    var isActive: Bool
}

final class PlaybackStateStore {
    static let shared = PlaybackStateStore()

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "playback.state.store")

    init() {
        fileURL = AppLog.directory.appendingPathComponent("session.json")
    }

    func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        ioQueue.async { [fileURL] in
            let tmp = fileURL.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp, options: .atomic)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: fileURL)
                }
            } catch {
                AppLog.log("snapshot.save failed: \(error.localizedDescription)")
            }
        }
    }

    func load() -> SessionSnapshot? {
        // **必须走到 ioQueue 上再读**，不能直接读文件。
        // `save` 是异步落盘的，而"退出听写 → 回首页读快照"这条路径上，
        // `stop()`/`pause()` 刚 save 完就 dismiss，`onDismiss` 紧接着 load。
        // 直接读的话多半读到的是**上一版文件**（甚至读不到），
        // 表现就是"刚练完，首页却说没有中断记录"。
        // 用 sync 是刻意的：读一个几 KB 的 JSON，阻塞量级可以忽略，
        // 换来的是"写完必读得到"这个确定性。
        ioQueue.sync { () -> SessionSnapshot? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONCoding.lenientDecoder().decode(SessionSnapshot.self, from: data)
        }
    }

    func clear() {
        ioQueue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 可恢复的会话：未完成、且不是太久以前。
    func loadRecoverable(maxAge: TimeInterval = 12 * 3600) -> SessionSnapshot? {
        guard let snapshot = load(), snapshot.isActive else { return nil }
        guard Date().timeIntervalSince(snapshot.updatedAt) < maxAge else {
            clear()
            return nil
        }
        return snapshot
    }
}

import Foundation
import Combine
import WatchConnectivity

/// iPhone 端数据层：词库管理、持久化、向 Watch 同步。
final class IOSStore: NSObject, ObservableObject {

    enum SyncStatus: Equatable {
        case idle
        case sending
        /// 已经交给系统队列，但手表还没确认。手表 App 没打开时就会一直停在这里，
        /// 这不是错误——所以不能显示成"失败"。
        case queued(version: Int)
        case success(entryCount: Int, version: Int)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "尚未同步"
            case .sending: return "正在发送…"
            case .queued(let version): return "已发送 v\(version)，等手表确认（打开手表 App 即完成）"
            case .success(let count, let version): return "手表已收到 \(count) 条（v\(version)）"
            case .failed(let message): return "同步失败：\(message)"
            }
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        var isPending: Bool {
            switch self {
            case .sending, .queued: return true
            default: return false
            }
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    struct StoreFile: Codable {
        var schemaVersion: Int
        var dataVersion: Int
        var lastSyncAt: Date?
        var libraries: [WordLibrary]
        var settings: AppSettings
    }

    @Published private(set) var libraries: [WordLibrary] = []
    @Published private(set) var settings: AppSettings = .default
    @Published private(set) var dataVersion: Int = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var watchVoices: [SpeechVoice] = []
    /// 手表主动上报的"实际生效参数"。侧载安装时系统状态不可信，以这个为准。
    @Published private(set) var watchState: WatchStateReport?
    @Published private(set) var lastWatchContactAt: Date?
    /// 上一次同步的端到端往返毫秒数。给用户看"多久"这件事，比"成功"两个字有信息量。
    @Published private(set) var lastRTT: Int?
    @Published private(set) var isReachable = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published var lastError: String?

    private let fileURL: URL
    private var pendingAckVersion: Int?
    private var ackTimer: Timer?
    private var sendStartedAt: Date?
    private var lastSendAt = Date.distantPast
    private var pendingSync: DispatchWorkItem?
    private var lastAckedVersion = 0

    override init() {
        fileURL = AppLog.directory.appendingPathComponent("phone-libraries.json")
        super.init()
        load()
        activateSession()
    }

    // MARK: 持久化

    private var fileSnapshot: StoreFile {
        StoreFile(schemaVersion: SyncProtocol.schemaVersion,
                  dataVersion: dataVersion,
                  lastSyncAt: lastSyncAt,
                  libraries: libraries,
                  settings: settings)
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONCoding.lenientDecoder().decode(StoreFile.self, from: data) else {
            if libraries.isEmpty { seedIfNeeded() }
            return
        }
        libraries = file.libraries
        settings = file.settings
        dataVersion = file.dataVersion
        lastSyncAt = file.lastSyncAt
        AppLog.log("phone.load libraries=\(libraries.count)")
    }

    private func seedIfNeeded() {
        // 首次启动给一个可直接试跑的示例词库，避免空白屏。
        let demo = WordLibrary(
            name: "易错成语",
            entries: ["鞭辟入里", "相形见绌", "饮鸩止渴", "罄竹难书", "学而不思则罔，思而不学则殆"]
                .map { VocabularyEntry(text: $0) },
            mode: .sequential
        )
        libraries = [demo]
        save()
    }

    func save() {
        guard let data = try? JSONCoding.encoder.encode(fileSnapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: 词库操作

    func library(id: UUID) -> WordLibrary? {
        libraries.first { $0.id == id }
    }

    func addLibrary(name: String) {
        let lib = WordLibrary(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新词库" : name)
        libraries.append(lib)
        save()
        schedulePush()
    }

    func deleteLibrary(id: UUID) {
        libraries.removeAll { $0.id == id }
        save()
        schedulePush()
    }

    func updateLibrary(id: UUID, _ mutate: (inout WordLibrary) -> Void) {
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&libraries[index])
        libraries[index].updatedAt = Date()
        save()
        schedulePush()
    }

    func addEntry(libraryID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateLibrary(id: libraryID) { lib in
            lib.entries.append(VocabularyEntry(text: trimmed))
        }
    }

    func addEntries(libraryID: UUID, entries: [VocabularyEntry], replace: Bool) {
        updateLibrary(id: libraryID) { lib in
            if replace {
                lib.entries = entries
            } else {
                lib.entries.append(contentsOf: entries)
            }
        }
    }

    func updateEntry(libraryID: UUID, entry: VocabularyEntry) {
        updateLibrary(id: libraryID) { lib in
            if let idx = lib.entries.firstIndex(where: { $0.id == entry.id }) {
                lib.entries[idx] = entry
            }
        }
    }

    func deleteEntries(libraryID: UUID, ids: Set<UUID>) {
        updateLibrary(id: libraryID) { lib in
            lib.entries.removeAll { ids.contains($0.id) }
        }
    }

    func toggleEntry(libraryID: UUID, entryID: UUID) {
        updateLibrary(id: libraryID) { lib in
            if let idx = lib.entries.firstIndex(where: { $0.id == entryID }) {
                lib.entries[idx].isEnabled.toggle()
            }
        }
    }

    func moveEntries(libraryID: UUID, from source: IndexSet, to destination: Int) {
        updateLibrary(id: libraryID) { lib in
            lib.entries.move(fromOffsets: source, toOffset: destination)
        }
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        save()
        schedulePush()
    }

    // MARK: 导入

    func importOutcomeSummary(_ outcome: ImportOutcome) -> String {
        var parts = ["成功 \(outcome.successCount) 条"]
        if outcome.duplicateCount > 0 { parts.append("跳过重复 \(outcome.duplicateCount) 条") }
        if !outcome.failures.isEmpty { parts.append("失败 \(outcome.failures.count) 条") }
        return parts.joined(separator: "，")
    }

    // MARK: 同步

    private func activateSession() {
        guard WCSession.isSupported() else {
            AppLog.log("phone.session unsupported")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func refreshSessionState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        // 历史上下文不算"刚刚通信"，只用来恢复语音列表与手表状态。
        ingest(session.receivedApplicationContext, markContact: false)
    }

    private func ingest(_ context: [String: Any], markContact: Bool) {
        var touched = false
        if let data = context[SyncProtocol.Key.voices] as? Data,
           let voices = try? JSONCoding.decoder.decode([SpeechVoice].self, from: data) {
            watchVoices = voices
            touched = true
        }
        if let data = context[SyncProtocol.Key.state] as? Data,
           let state = try? JSONCoding.decoder.decode(WatchStateReport.self, from: data),
           state.reportedAt >= (watchState?.reportedAt ?? .distantPast) {
            // 只接受更新的快照。`receivedApplicationContext` 里躺着的是手表上一次
            // 主动推送的旧包，直接覆盖会让界面在 v11 / v10 之间来回跳。
            watchState = state
            touched = true
        }
        if touched, markContact {
            lastWatchContactAt = Date()
        }
        if touched {
            AppLog.log("phone.ingest voices=\(watchVoices.count) watchState=\(watchState?.summary ?? "nil")")
        }
    }

    /// 给界面用的一句话"最近通信"。
    var lastContactText: String {
        guard let date = lastWatchContactAt else { return "从未通信" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var watchStateSummary: String {
        watchState?.summary ?? "尚未收到手表上报"
    }

    /// 把词库 + 设置推给手表。
    ///
    /// 通道选择直接决定等待时间，差一个数量级：
    ///
    /// | 通道 | 延迟 | 说明 |
    /// |---|---|---|
    /// | `sendMessage` | 0.1–0.3 秒 | 两端都在前台；回执在同一次往返返回 |
    /// | `updateApplicationContext` | 数秒 ~ 数十秒 | 排队投递，保证送达但不保证及时 |
    /// | `transferFile` | 更慢 | 只在包超过 200KB 时用 |
    ///
    /// 以前只走 `applicationContext`，一次同步其实是「发 + 回执 + 手表推状态」
    /// 三个排队跳串起来，所以哪怕只加一条词也慢。现在优先快车道。
    ///
    /// - Parameter force: 用户显式点的"立即推送"，不做合并。
    func syncToWatch(force: Bool = false) {
        guard force else {
            // 尾随合并：1.2 秒内反复触发（滑块、连点、启动自愈叠加）只保留最后一次，
            // 既不会丢改动，也不会把同一个状态发成一串。
            let minGap: TimeInterval = 1.2
            let elapsed = Date().timeIntervalSince(lastSendAt)
            if elapsed >= minGap {
                performSync()
            } else {
                pendingSync?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.performSync() }
                pendingSync = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (minGap - elapsed), execute: work)
                AppLog.log("phone.sync coalesced（\(String(format: "%.2f", elapsed))s 内重复触发，合并成一次）")
            }
            return
        }
        performSync()
    }

    private func performSync() {
        pendingSync = nil
        guard WCSession.isSupported() else {
            syncStatus = .failed("此设备不支持手表连接")
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            syncStatus = .failed("连接尚未就绪，请稍后重试")
            return
        }
        guard session.isPaired else {
            syncStatus = .failed("尚未与手表配对")
            return
        }
        // 注意：不把 isWatchAppInstalled 当硬门槛。
        // 用 Xcode / devicectl 直接装到手表时，iOS 侧的 NanoRegistry 状态可能长期为 false，
        // 但 WCSession 本身是通的。这里只记录告警，照常发送；真送不到会由
        // updateApplicationContext 抛错或 ack 超时暴露真实原因，比直接拒绝有用。
        if !session.isWatchAppInstalled {
            AppLog.log("phone.sync warn: isWatchAppInstalled=false（侧载安装的常见状态），仍尝试发送")
        }
        guard !libraries.isEmpty else {
            syncStatus = .failed("没有可同步的词库")
            return
        }

        let nextVersion = dataVersion + 1
        do {
            let built = try SyncProtocol.makeEnvelope(libraries: libraries,
                                                      settings: settings,
                                                      dataVersion: nextVersion)
            syncStatus = .sending
            pendingAckVersion = nextVersion
            sendStartedAt = Date()
            lastSendAt = Date()

            let payload: [String: Any] = [SyncProtocol.Key.envelope: built.data]
            let bytes = built.data.count

            switch built.channel {
            case .file:
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sync-\(nextVersion).json")
                try built.data.write(to: url, options: .atomic)
                session.transferFile(url, metadata: ["dataVersion": nextVersion])
                AppLog.log("phone.sync file version=\(nextVersion) bytes=\(bytes)")
            case .applicationContext:
                if bytes <= SyncProtocol.fastLaneLimit {
                    deliverFast(payload, version: nextVersion, bytes: bytes, session: session)
                } else {
                    sendViaContext(payload, version: nextVersion, bytes: bytes, session: session)
                }
            }

            dataVersion = nextVersion
            save()
            startAckTimeout()
        } catch {
            syncStatus = .failed(error.localizedDescription)
            AppLog.log("phone.sync failed: \(error.localizedDescription)")
        }
    }

    /// 快车道：`sendMessage` + `replyHandler`。回执和手表状态在同一次往返里回来，
    /// 不需要手表再单独发一趟。
    private func deliverFast(_ payload: [String: Any],
                             version: Int,
                             bytes: Int,
                             session: WCSession) {
        session.sendMessage(payload, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ingest(reply, markContact: true)
                if let data = reply[SyncProtocol.Key.ack] as? Data {
                    self.handleAck(data)
                } else {
                    // 送到了但对方没带回执（例如手表还是旧版本），退回排队通道保证有确认。
                    AppLog.log("phone.sync fastlane 无回执 → 退回 context")
                    self.sendViaContext(payload, version: version, bytes: bytes, session: session)
                }
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                // 最常见的原因：手表 App 不在前台（isReachable=false）。
                // 这不是错误，退回排队通道即可，下次抬腕就能收到。
                AppLog.log("phone.sync fastlane 不可达：\(error.localizedDescription) → 退回 context")
                self.sendViaContext(payload, version: version, bytes: bytes, session: session)
            }
        })
    }

    private func sendViaContext(_ payload: [String: Any],
                                version: Int,
                                bytes: Int,
                                session: WCSession) {
        // 已经拿到回执就不要再用排队通道补一包。
        guard pendingAckVersion != nil else { return }
        do {
            try session.updateApplicationContext(payload)
            AppLog.log("phone.sync context version=\(version) bytes=\(bytes)")
        } catch {
            syncStatus = .failed(error.localizedDescription)
            AppLog.log("phone.sync context failed: \(error.localizedDescription)")
        }
    }

    private func startAckTimeout() {
        ackTimer?.invalidate()
        let sentVersion = pendingAckVersion
        ackTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, self.pendingAckVersion != nil else { return }
            // 到点没回执 ≠ 失败。applicationContext / userInfo 都是排队投递，
            // 手表 App 没开时会静静躺在系统队列里，下次打开才送达。
            self.pendingAckVersion = nil
            self.syncStatus = .queued(version: sentVersion ?? self.dataVersion)
            AppLog.log("phone.sync queued version=\(sentVersion ?? -1)（无回执，等手表上线）")
        }
    }

    private func handleAck(_ data: Data) {
        guard let ack = try? JSONCoding.decoder.decode(SyncAck.self, from: data) else { return }
        // 同一版会收到多条回执：手表在激活瞬间会把最后一包重放一次，
        // 每次都会回一条。第一条已经更新过状态了，后面的只留日志。
        guard ack.dataVersion > lastAckedVersion || pendingAckVersion == ack.dataVersion else {
            AppLog.log("phone.sync ack dup version=\(ack.dataVersion)（忽略）")
            return
        }
        lastAckedVersion = max(lastAckedVersion, ack.dataVersion)
        ackTimer?.invalidate()
        pendingAckVersion = nil
        lastWatchContactAt = Date()
        lastSyncAt = ack.receivedAt
        syncStatus = .success(entryCount: ack.entryCount, version: ack.dataVersion)
        let rtt = sendStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        sendStartedAt = nil
        if rtt >= 0 { lastRTT = rtt }
        save()
        AppLog.log("phone.sync ack version=\(ack.dataVersion) entries=\(ack.entryCount) applied=\(ack.applied ?? true) rtt=\(rtt)ms")
        // 这里**不**再调 refreshSessionState()：它会把 receivedApplicationContext
        // 里手表上一次推的旧状态读回来，覆盖掉刚刚拿到的这一包。
    }

    /// 设置改完立刻推送，省掉"改完还要记得点同步"这一步。
    func saveAndSync() {
        save()
        // 显式保存：用户刚按的按钮，任何情况下都要真发出去，不参与合并。
        syncToWatch(force: true)
    }

    /// 内容一改就在后台排一次推送（1.2 秒内合并）。
    ///
    /// 目的：把"同步"这件事从"记得去同步页点一下"变成自动发生。
    /// 用户新增一条词、关掉页面时，包已经在路上了，抬腕就能看到，
    /// 主观上就不存在"同步要等"这件事。
    private func schedulePush() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        syncToWatch()
    }

    /// 启动时自愈：手表的版本落后（或从没同步过）就补推一次。
    /// 手机上改完参数、手表当时不在，下次打开手机 App 会自动补上。
    func autoSyncIfNeeded() {
        guard !libraries.isEmpty else { return }
        let watchVersion = watchState?.dataVersion ?? 0
        guard watchVersion < dataVersion || lastSyncAt == nil else { return }
        syncToWatch()
    }

    // MARK: 导出

    func exportArchiveData() -> Data? {
        DictionaryIO.exportArchive(libraries: libraries, settings: settings)
    }
}

// MARK: - WCSessionDelegate

extension IOSStore: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshSessionState()
            if let error {
                self?.lastError = error.localizedDescription
            }
        }
        AppLog.log("phone.activation=\(activationState.rawValue)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        AppLog.log("phone.sessionInactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // 切换手表后需要重新激活
        session.activate()
        AppLog.log("phone.sessionDeactivated")
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshSessionState()
        }
    }

    /// 手表的回包现在是一整包（回执 + 状态 + 语音），三个键一起处理。
    private func handleIncoming(_ dict: [String: Any]) {
        ingest(dict, markContact: true)
        if let data = dict[SyncProtocol.Key.ack] as? Data {
            handleAck(data)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.handleIncoming(message)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async { [weak self] in
            self?.handleIncoming(userInfo)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.ingest(applicationContext, markContact: true)
        }
    }
}

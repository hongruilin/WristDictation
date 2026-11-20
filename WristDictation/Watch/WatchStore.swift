import Foundation
import Combine

/// Watch 端本地词库。写入必须是原子的：
/// 半成品绝不能覆盖正在使用的完整词库（验收 A23 / I06）。
final class WatchStore: ObservableObject {

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

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "watch.store.io")
    /// 上一次交出去的状态快照。内容没变就原样返回（连 `reportedAt` 都不动），
    /// 否则同步层永远认不出重复包。
    private var cachedReport: WatchStateReport?

    init() {
        fileURL = AppLog.directory.appendingPathComponent("libraries.json")
        load()
    }

    var hasContent: Bool { !libraries.isEmpty }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            AppLog.log("store.load empty")
            seedSampleIfNeeded()
            return
        }
        guard let file = try? JSONCoding.lenientDecoder().decode(StoreFile.self, from: data) else {
            AppLog.log("store.load decode failed")
            seedSampleIfNeeded()
            return
        }
        libraries = file.libraries
        settings = file.settings
        dataVersion = file.dataVersion
        lastSyncAt = file.lastSyncAt
        AppLog.log("store.load libraries=\(libraries.count) version=\(dataVersion)")
        seedSampleIfNeeded()
    }

    /// 本地一条词库都没有时，注入内置示例词库。
    ///
    /// 为什么需要：侧载安装（devicectl / Xcode 直接装）时，iOS 侧的
    /// `WCSession.isWatchAppInstalled` 可能长期为 false，手机端同步被卡住；
    /// 而手表端没内容就什么也验不了。这份示例是离线兜底，
    /// 一旦手机同步成功，会被真实词库整体替换。
    private func seedSampleIfNeeded() {
        guard libraries.isEmpty else { return }
        let sample = SampleContent.library()
        libraries = [sample]
        dataVersion = 0
        persist()
        AppLog.log("store.seed sample entries=\(sample.entries.count)")
    }

    private func persist() {
        let file = StoreFile(schemaVersion: SyncProtocol.schemaVersion,
                             dataVersion: dataVersion,
                             lastSyncAt: lastSyncAt,
                             libraries: libraries,
                             settings: settings)
        guard let data = try? JSONCoding.encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 手表端直接调参，不依赖手机同步。手滑与否由 UI 层夹紧范围。
    func updateGlobal(_ layer: ParameterLayer) {
        settings.global = layer
        persist()
        AppLog.log("store.updateGlobal repeat=\(layer.repeatCount ?? -1) same=\(layer.sameWordGap ?? -1) next=\(layer.nextWordGap ?? -1) manual=\(layer.isManualAdvance ?? false)")
    }

    func library(id: UUID) -> WordLibrary? {
        libraries.first { $0.id == id }
    }

    /// 校验通过后原子替换。失败时保留旧数据。
    func apply(_ payload: SyncPayload, version: Int) throws {
        guard !payload.libraries.isEmpty else {
            throw SyncError.emptyPayload
        }

        let file = StoreFile(schemaVersion: SyncProtocol.schemaVersion,
                             dataVersion: version,
                             lastSyncAt: Date(),
                             libraries: payload.libraries,
                             settings: payload.settings)

        let data = try JSONCoding.encoder.encode(file)
        let tmp = fileURL.appendingPathExtension("tmp")

        try data.write(to: tmp, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }

        libraries = payload.libraries
        settings = payload.settings
        dataVersion = version
        lastSyncAt = file.lastSyncAt

        AppLog.log("store.applied version=\(version) libraries=\(libraries.count)")
    }

    func localVoiceIdentifier() -> String? { settings.voiceIdentifier }

    /// 供 iPhone 展示的"手表当前生效"快照。
    ///
    /// `reportedAt` 刻意**只在内容变化时**刷新：手机侧是按这个时间戳比新旧、只收更新的
    /// 那一份，如果内容没变却每次都给新时间戳，同步层就永远判不出"这包是重复的"，
    /// 可达性每次抖动都要白发一趟（V1.6.1 实测 4 分钟 14 次）。
    func stateReport() -> WatchStateReport {
        let resolved = settings.global.merged(over: ParameterResolver.absoluteDefault)
        let voiceName = settings.voiceIdentifier.flatMap { id in
            SystemSpeechService.availableSystemVoices().first { $0.id == id }?.name
        }
        let draft = WatchStateReport(
            dataVersion: dataVersion,
            libraryCount: libraries.count,
            entryCount: libraries.reduce(0) { $0 + $1.entries.count },
            repeatCount: resolved.repeatCount ?? 2,
            sameWordGap: resolved.sameWordGap ?? 3,
            nextWordGap: resolved.nextWordGap ?? 5,
            isManualAdvance: resolved.isManualAdvance ?? false,
            voiceName: voiceName,
            speechRate: settings.speechRate,
            powerSaving: settings.powerSaving,
            reportedAt: Date()
        )
        if let cached = cachedReport, cached.sameContent(as: draft) {
            return cached
        }
        cachedReport = draft
        return draft
    }

    func updateVoice(_ identifier: String?) {
        guard var file = currentFileForMutation() else { return }
        file.settings.voiceIdentifier = identifier
        guard let data = try? JSONCoding.encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
        settings.voiceIdentifier = identifier
    }

    func updateSpeechRate(_ rate: Double) {
        guard var file = currentFileForMutation() else { return }
        file.settings.speechRate = rate
        guard let data = try? JSONCoding.encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
        settings.speechRate = rate
    }

    private func currentFileForMutation() -> StoreFile? {
        StoreFile(schemaVersion: SyncProtocol.schemaVersion,
                  dataVersion: dataVersion,
                  lastSyncAt: lastSyncAt,
                  libraries: libraries,
                  settings: settings)
    }
}

// MARK: - 内置示例词库

/// 手表端离线兜底内容。见 `seedSampleIfNeeded()` 的说明。
enum SampleContent {

    static let words = [
        "春天", "图书馆", "勇敢", "安静", "铅笔",
        "微笑", "清晨", "朋友", "森林", "河流",
    ]

    static func library() -> WordLibrary {
        WordLibrary(
            name: "示例词库",
            entries: words.map { VocabularyEntry(text: $0) },
            defaults: ParameterLayer(repeatCount: 2,
                                     sameWordGap: 2,
                                     nextWordGap: 5,
                                     isManualAdvance: false),
            mode: .sequential
        )
    }
}

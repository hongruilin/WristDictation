import Foundation

// MARK: - 播放模式

enum PlaybackMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case sequential
    case shuffle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sequential: return "顺序"
        case .shuffle: return "随机"
        }
    }

    var detail: String {
        switch self {
        case .sequential: return "按词库顺序播报，每词按设定次数重复"
        case .shuffle: return "播报顺序随机；每词的次数与间隔完全同顺序模式，同一词本轮只出现一组"
        }
    }
}

// MARK: - 词条

struct VocabularyEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var isEnabled: Bool
    /// 仅保存用户显式设置的字段，nil 表示继承上层。
    var overrides: ParameterLayer

    init(id: UUID = UUID(),
         text: String,
         isEnabled: Bool = true,
         overrides: ParameterLayer = ParameterLayer()) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
        self.overrides = overrides
    }

    /// 用于去重与比较：去首尾空白、全角空格转半角、去首尾标点。
    static func normalized(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\u{3000}", with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimSet = CharacterSet(charactersIn: "，。、；：？！“”‘’（）《》〈〉【】—…·,.;:?!\"'()[]{}<>")
        s = s.trimmingCharacters(in: trimSet)
        return s.lowercased()
    }

    var normalizedText: String { VocabularyEntry.normalized(text) }

    /// 词条用到的字数（用于估算本轮时长）。
    var characterCount: Int { max(1, text.count) }
}

// MARK: - 词库

struct WordLibrary: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var entries: [VocabularyEntry]
    /// 词库层默认参数，覆盖全局层。
    var defaults: ParameterLayer
    var mode: PlaybackMode
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         entries: [VocabularyEntry] = [],
         defaults: ParameterLayer = ParameterLayer(),
         mode: PlaybackMode = .sequential,
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.entries = entries
        self.defaults = defaults
        self.mode = mode
        self.updatedAt = updatedAt
    }

    var enabledEntries: [VocabularyEntry] {
        entries.filter { $0.isEnabled && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var enabledCount: Int { enabledEntries.count }
}

// MARK: - 全局设置

struct AppSettings: Codable, Hashable {
    /// 全局默认参数，位于继承链最底层（次于绝对默认值）。
    var global: ParameterLayer
    /// 语速，映射到 AVSpeechUtterance.rate。
    var speechRate: Double
    /// 语音标识。nil 表示使用系统默认普通话。
    var voiceIdentifier: String?
    /// 省电模式：念完一个词后停掉静音保活轨，到下一个词再拉起来。
    ///
    /// 这是唯一能真正省下「音频管线 + 蓝牙持续流式传输」的开关——那部分占本 App
    /// 耗电的大头。代价是空档与暂停期间系统不再认为本 App 在播放：耳机键会失效，
    /// 熄屏后进程还可能被挂起（抬腕时自动续上）。
    /// 默认关闭，因为默认行为必须是「耳机键随时可用」。
    var powerSaving: Bool

    static let `default` = AppSettings(
        global: ParameterLayer(repeatCount: 2, sameWordGap: 3, nextWordGap: 5, isManualAdvance: false),
        speechRate: 0.45,
        voiceIdentifier: nil,
        powerSaving: false
    )

    init(global: ParameterLayer,
         speechRate: Double,
         voiceIdentifier: String?,
         powerSaving: Bool = false) {
        self.global = global
        self.speechRate = speechRate
        self.voiceIdentifier = voiceIdentifier
        self.powerSaving = powerSaving
    }

    private enum CodingKeys: String, CodingKey {
        case global, speechRate, voiceIdentifier, powerSaving
    }

    /// 手写解码的原因只有一个：老版本落盘的 JSON 里没有 `powerSaving`。
    /// 用合成的解码器会在缺键时抛错，导致整份设置（连带词库文件）被当成损坏。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        global = try c.decode(ParameterLayer.self, forKey: .global)
        speechRate = try c.decode(Double.self, forKey: .speechRate)
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        powerSaving = try c.decodeIfPresent(Bool.self, forKey: .powerSaving) ?? false
    }
}

// MARK: - 答案单

/// 本轮实际播放过的一条记录，按真实播放顺序追加。
struct PlayedItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var order: Int
    var text: String
    var plays: Int
}

/// 一次完整或中断的听写结果，供"上一轮答案"回看。
struct AnswerSheet: Identifiable, Codable, Hashable {
    var id = UUID()
    var libraryName: String
    var items: [PlayedItem]
    var elapsed: String
    var finishedAt: Date
    var isComplete: Bool
}

// MARK: - 语音

/// 手表端实际可用的系统语音。iPhone 通过同步拿到这份列表后，
/// 只允许用户选手表上真实存在的语音（PRD 6.3）。
struct SpeechVoice: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var language: String
    var qualityLabel: String
}

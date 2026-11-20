import Foundation

// MARK: - 参数层级

/// 三层参数（全局 / 词库 / 词条）的单层表示。
/// 每个字段都是可选：nil 表示这一层没有显式设置，继续向上继承。
/// 不能用"值等于默认值"来推断"未设置"，否则用户把某词显式设为默认值后，
/// 上层改动会穿透下来。
struct ParameterLayer: Codable, Hashable {
    var repeatCount: Int?
    var sameWordGap: Double?
    var nextWordGap: Double?
    var isManualAdvance: Bool?

    init(repeatCount: Int? = nil,
         sameWordGap: Double? = nil,
         nextWordGap: Double? = nil,
         isManualAdvance: Bool? = nil) {
        self.repeatCount = repeatCount
        self.sameWordGap = sameWordGap
        self.nextWordGap = nextWordGap
        self.isManualAdvance = isManualAdvance
    }

    var isEmpty: Bool {
        repeatCount == nil && sameWordGap == nil && nextWordGap == nil && isManualAdvance == nil
    }

    /// 用 self 覆盖 base，self 中为 nil 的字段保留 base 的值。
    func merged(over base: ParameterLayer) -> ParameterLayer {
        ParameterLayer(
            repeatCount: repeatCount ?? base.repeatCount,
            sameWordGap: sameWordGap ?? base.sameWordGap,
            nextWordGap: nextWordGap ?? base.nextWordGap,
            isManualAdvance: isManualAdvance ?? base.isManualAdvance
        )
    }
}

// MARK: - 取值边界

enum ParameterLimits {
    static let repeatCountRange = 1...20
    static let gapRange: ClosedRange<Double> = 0...600

    static func clampRepeat(_ value: Int) -> Int {
        min(max(value, repeatCountRange.lowerBound), repeatCountRange.upperBound)
    }

    static func clampGap(_ value: Double) -> Double {
        min(max(value, gapRange.lowerBound), gapRange.upperBound)
    }

    /// 输入框展示用：去掉多余小数。
    static func formatGap(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - 最终生效参数

struct ResolvedParameters: Hashable {
    var repeatCount: Int
    var sameWordGap: TimeInterval
    var nextWordGap: TimeInterval
    var isManualAdvance: Bool

    // 注意：曾经这里有一个 `effective(for: PlaybackMode)`，在随机模式下把
    // repeatCount 强改成 1、sameWordGap 强改成 0。那是错的——
    // 它让"随机"变成了"每个词只念一遍"，连带预计时长从 1 分 22 秒掉到 48 秒。
    // 现在随机只决定**顺序**：队列洗一次牌，每词仍按设定次数连续播报、
    // 仍用同词间隔，播完这一组就进入下一个词，本轮不再回头。

    /// 粗略估算该词播完需要多久（秒），用于会话时长预算提示。
    var estimatedDuration: TimeInterval {
        let speechPerPlay = 0.9 // 中文约每字 0.3 秒，这里按词条平均长度另算
        let repeats = TimeInterval(max(1, repeatCount))
        return repeats * speechPerPlay + repeats * sameWordGap + nextWordGap
    }
}

// MARK: - 解析器

enum ParameterResolver {
    /// 绝对默认值：所有层都没设置时的兜底。
    static let absoluteDefault = ParameterLayer(
        repeatCount: 2,
        sameWordGap: 3,
        nextWordGap: 5,
        isManualAdvance: false
    )

    /// 全局 → 词库 → 词条，逐层覆盖。
    static func resolve(settings: AppSettings,
                        library: WordLibrary,
                        entry: VocabularyEntry) -> ResolvedParameters {
        let merged = entry.overrides
            .merged(over: library.defaults)
            .merged(over: settings.global)
            .merged(over: absoluteDefault)

        return ResolvedParameters(
            repeatCount: ParameterLimits.clampRepeat(merged.repeatCount ?? 2),
            sameWordGap: ParameterLimits.clampGap(merged.sameWordGap ?? 3),
            nextWordGap: ParameterLimits.clampGap(merged.nextWordGap ?? 5),
            isManualAdvance: merged.isManualAdvance ?? false
        )
    }

    static func resolveAll(settings: AppSettings, library: WordLibrary) -> [ResolvedParameters] {
        library.enabledEntries.map { resolve(settings: settings, library: library, entry: $0) }
    }

    /// 本轮预计时长（秒），用于"较长建议分段"的提示（PRD 9.4 产品侧缓解）。
    /// 中文语音约每字 0.32 秒，另加起播开销。
    static func estimateDuration(library: WordLibrary, settings: AppSettings) -> TimeInterval {
        let entries = library.enabledEntries
        guard !entries.isEmpty else { return 0 }
        var total: TimeInterval = 0
        for entry in entries {
            // 随机只改顺序，不改单条参数：两种模式的预计时长必须一致。
            let p = resolve(settings: settings, library: library, entry: entry)
            let speech = Double(entry.characterCount) * 0.32 + 0.35
            total += speech * Double(p.repeatCount)
            total += p.sameWordGap * Double(max(0, p.repeatCount - 1))
            if !p.isManualAdvance {
                total += p.nextWordGap
            }
        }
        return total
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(rest) 秒"
    }
}

// MARK: - 选项预设（手机与手表共用同一套刻度）

enum ParameterPresets {
    static let repeatChoices = [1, 2, 3, 4, 5]
    static let gaps: [Double] = [1, 2, 3, 4, 5, 8, 10, 15, 20, 30, 60, 120, 300, 600]

    static func gapOptions(including value: Double) -> [Double] {
        var base = gaps
        if !base.contains(value) {
            base.append(value)
            base.sort()
        }
        return base
    }

    static func gapLabel(_ value: Double) -> String {
        if value < 60 { return "\(Int(value)) 秒" }
        let minutes = Int(value) / 60
        let rest = Int(value) % 60
        return rest == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(rest) 秒"
    }
}

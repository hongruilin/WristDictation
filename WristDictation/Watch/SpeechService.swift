import Foundation
import AVFoundation

// MARK: - 协议

/// 语音合成抽象。V1.0 用系统 TTS 实现；
/// 若 V-01 后台验证失败需要改用"烘焙音频队列"，只需替换此协议的实现，
/// 引擎与界面不感知。
protocol SpeechService: AnyObject {
    var onFinish: ((UUID) -> Void)? { get set }
    /// 合成器是否真的在出声（或处于系统暂停）。
    ///
    /// 存在的唯一理由是给引擎做**看门狗**：`AVSpeechSynthesizer` 在
    /// App 退到后台、音频路由被抢、音频会话被回收这几种情况下，会回调
    /// `didStart` 但**永远不回调 `didFinish`**，也不出声。状态机就卡在
    /// `.speaking`，界面显示"播放中"、实际一片安静，而且不会自己恢复。
    ///
    /// 引擎在看门狗里问这个属性（仅在 `.speaking` 期间，间隔期不跑）。
    var isSpeaking: Bool { get }

    /// 本次开口是否已经收到 `didStart`。
    ///
    /// 看门狗用它区分两种"合成器不吭声"，两者性质完全不同：
    /// - `false`：`speak()` 之后系统还在加载语音包 / 排队占用音频路由。
    ///   此时 `isSpeaking` 短暂为假是**正常**的，判失败就会跳词。
    ///   除非等得太离谱（引擎侧有独立超时），否则一律不计失败。
    /// - `true`：已经开口了，却既不推进也不回调 `didFinish`——这才是真病，
    ///   也是后台播报那个案例的实际形态。
    var didStartCurrent: Bool { get }
    func speak(_ text: String, rate: Float, voiceIdentifier: String?) -> UUID
    func stop()
    func availableVoices() -> [SpeechVoice]
}

// MARK: - 系统 TTS 实现

final class SystemSpeechService: NSObject, SpeechService, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var currentToken: UUID?
    private var stoppedToken: UUID?
    /// 已经对本 token 回调过 `didStart`。`speak()` 时清空，
    /// 供看门狗判断"是还没开口"还是"开了口不出声"。
    private var startedToken: UUID?

    var onFinish: ((UUID) -> Void)?

    /// `isPaused` 也算"活着"：系统级暂停（来电、Siri 抢占）时合成器不推进，
    /// 但它并没有死，硬判成"播完"会跳词。只有两者都为假才是真的没在跑。
    var isSpeaking: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused
    }

    var didStartCurrent: Bool {
        startedToken != nil && startedToken == currentToken
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        // 默认就是 true，这里显式写出来：TTS 必须走 App 自己的音频会话，
        // 否则它内部另起一个会话，我们这个 App 就永远不会成为 Now Playing，
        // 耳机按键也就收不到。
        synthesizer.usesApplicationAudioSession = true
    }

    func speak(_ text: String, rate: Float, voiceIdentifier: String?) -> UUID {
        // 上一次可能还没结束，先硬停，避免两条语音重叠
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let token = UUID()
        currentToken = token
        startedToken = nil

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0
        utterance.volume = 1.0

        if let identifier = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: "zh-CN") {
            utterance.voice = voice
        }

        synthesizer.speak(utterance)
        return token
    }

    func stop() {
        stoppedToken = currentToken
        currentToken = nil
        startedToken = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func availableVoices() -> [SpeechVoice] {
        Self.availableSystemVoices()
    }

    /// 枚举本机可用的中文语音，并标注音质等级。
    /// watchOS 默认只带标准语音，增强版需要用户在手表设置里下载，
    /// 因此在界面上必须区分出来（PRD 7.2.1）。
    ///
    /// **必须缓存**：`AVSpeechSynthesisVoice.speechVoices()` 在手表上要枚举
    /// 全部已安装语音包，实测耗时可达数百毫秒。同步回执、状态上报、
    /// 设置页加载都会调它，不缓存的话每次同步都白烧一遍。
    static func availableSystemVoices(forceRefresh: Bool = false) -> [SpeechVoice] {
        if !forceRefresh, let cache, Date().timeIntervalSince(cache.at) < 60 {
            return cache.voices
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .map { voice -> SpeechVoice in
                let quality: String
                switch voice.quality {
                case .enhanced: quality = "增强"
                case .premium: quality = "高级"
                default: quality = "标准"
                }
                return SpeechVoice(id: voice.identifier,
                                   name: voice.name,
                                   language: voice.language,
                                   qualityLabel: quality)
            }
            .sorted { lhs, rhs in
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                if lhs.qualityLabel != rhs.qualityLabel { return lhs.qualityLabel > rhs.qualityLabel }
                return lhs.name < rhs.name
            }
        cache = (voices, Date())
        return voices
    }

    /// 60 秒缓存。语音包在 App 运行期间不会变，够用了。
    private static var cache: (voices: [SpeechVoice], at: Date)?

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let token = currentToken else { return }
        currentToken = nil
        startedToken = nil
        AppLog.log("tts.didFinish \(token.uuidString.prefix(8))")
        onFinish?(token)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // 主动 stop 触发的取消不回调，避免被当成"播报完成"而误推进状态机。
        if let stopped = stoppedToken {
            AppLog.log("tts.didCancel(stopped) \(stopped.uuidString.prefix(8))")
            stoppedToken = nil
        } else {
            AppLog.log("tts.didCancel(unexpected)")
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let token = currentToken {
            startedToken = token
            AppLog.log("tts.didStart \(token.uuidString.prefix(8))")
        }
    }
}

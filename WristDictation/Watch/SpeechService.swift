import Foundation
import AVFoundation

// MARK: - 协议

/// 语音合成抽象。V1.0 用系统 TTS 实现；
/// 若 V-01 后台验证失败需要改用"烘焙音频队列"，只需替换此协议的实现，
/// 引擎与界面不感知。
protocol SpeechService: AnyObject {
    var onFinish: ((UUID) -> Void)? { get set }
    /// 合成器**自己**把这次开口丢掉了（不是我们调 `stop()`）。
    ///
    /// 没有可用输出路由时它就是这样：既不 `didStart` 也不 `didFinish`，
    /// 直接 `didCancel`。引擎据此判断"整条输出链路是死的"，
    /// 而不是把它当成播完继续往下翻词。
    var onCancel: ((UUID) -> Void)? { get set }
    /// 本次开口**最近一次真的往前推进**的时刻（`didStart` 或逐段朗读回调）。
    ///
    /// 看门狗的第二道判据：`isSpeaking` 只代表合成器内部状态是 speaking，
    /// 音频单元没在拉数据时它照样为真。2026-11-25 实测第一开口就卡死 14 秒、
    /// 界面停在第一个词不动，而 `isSpeaking` 始终为真——只看它永远发现不了。
    var lastProgressAt: Date { get }
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
    /// 是否让合成器走 App 自己的音频会话。
    ///
    /// 默认 `true`——只有这样本 App 才会成为 Now Playing，耳机按键才收得到命令。
    /// 置 `false` 是**兜底**：App 的会话彻底激活不起来时，让合成器自带会话发声，
    /// 至少还能听见词（代价是耳机键失效）。
    func setUsesApplicationAudioSession(_ enabled: Bool)
}

// MARK: - 系统 TTS 实现

final class SystemSpeechService: NSObject, SpeechService, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var currentToken: UUID?
    private var stoppedToken: UUID?
    /// 已经对本 token 回调过 `didStart`。`speak()` 时清空，
    /// 供看门狗判断"是还没开口"还是"开了口不出声"。
    private var startedToken: UUID?

    /// 当前这条 utterance 的**对象身份**。
    ///
    /// 委托回调不携带 token，只能靠身份判断回调属于哪一次开口。原来的写法
    /// 一律拿 `currentToken`，于是"上一条被新 speak 顶掉后迟到的 `didFinish`"
    /// 会被算到**新 token**头上——状态机以为新词已经念完，直接翻页。
    /// 2026-11-25 实测：13 个词在几秒内翻完、一个声音都没有，
    /// 日志里全是 `didCancel(unexpected)` + 同毫秒的 `didFinish`。
    private var currentUtterance: AVSpeechUtterance?
    private var progressAt = Date.distantPast

    var onFinish: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?

    /// `isPaused` 也算"活着"：系统级暂停（来电、Siri 抢占）时合成器不推进，
    /// 但它并没有死，硬判成"播完"会跳词。只有两者都为假才是真的没在跑。
    var isSpeaking: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused
    }

    var didStartCurrent: Bool {
        startedToken != nil && startedToken == currentToken
    }

    var lastProgressAt: Date { progressAt }

    override init() {
        super.init()
        synthesizer.delegate = self
        // 默认就是 true，这里显式写出来：TTS 必须走 App 自己的音频会话，
        // 否则它内部另起一个会话，我们这个 App 就永远不会成为 Now Playing，
        // 耳机按键也就收不到。
        synthesizer.usesApplicationAudioSession = true
    }

    func setUsesApplicationAudioSession(_ enabled: Bool) {
        guard synthesizer.usesApplicationAudioSession != enabled else { return }
        synthesizer.usesApplicationAudioSession = enabled
        AppLog.log("tts.applicationSession=\(enabled)")
    }

    func speak(_ text: String, rate: Float, voiceIdentifier: String?) -> UUID {
        // 上一次可能还没结束，先硬停，避免两条语音重叠
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let token = UUID()
        currentToken = token
        startedToken = nil
        // 从"请求开口"这一刻起算：看门狗用它测"多久没有任何推进"，
        // 因此必须在这里重置，不能等 didStart。
        progressAt = Date()

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

        currentUtterance = utterance
        synthesizer.speak(utterance)
        return token
    }

    func stop() {
        stoppedToken = currentToken
        currentToken = nil
        startedToken = nil
        // 置空身份：stop 之后到达的回调一律按"陈旧"处理，绝不能推进状态机。
        currentUtterance = nil
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
        // 只认**当前这条** utterance。迟到的上一条回调一律丢弃，
        // 否则新词会被凭空判定为"已播完"（见 currentUtterance 的注释）。
        guard utterance === currentUtterance, let token = currentToken else {
            AppLog.log("tts.didFinish(stale)")
            return
        }
        currentUtterance = nil
        currentToken = nil
        startedToken = nil
        AppLog.log("tts.didFinish \(token.uuidString.prefix(8))")
        onFinish?(token)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // 主动 stop 触发的取消不回调，避免被当成"播报完成"而误推进状态机。
        guard utterance === currentUtterance, let token = currentToken else {
            if let stopped = stoppedToken {
                AppLog.log("tts.didCancel(stopped) \(stopped.uuidString.prefix(8))")
                stoppedToken = nil
            } else {
                AppLog.log("tts.didCancel(stale)")
            }
            return
        }
        // 不是我们停的：合成器**自己放弃**了这次开口。没有可用输出路由时就是这样，
        // 必须让引擎知道，不能像原来那样只记一行日志然后让状态机永远等下去。
        currentUtterance = nil
        currentToken = nil
        startedToken = nil
        AppLog.log("tts.didCancel(unexpected) \(token.uuidString.prefix(8))")
        onCancel?(token)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance, let token = currentToken else { return }
        startedToken = token
        progressAt = Date()
        AppLog.log("tts.didStart \(token.uuidString.prefix(8))")
    }

    /// 逐段朗读回调 = 语音真的在往前走。
    ///
    /// 这是看门狗唯一可靠的"有进展"信号：`isSpeaking` 在音频单元卡死时仍为真，
    /// 而只要能念出一个字，这里就会被调用。日志做 2 秒节流，别把文件刷爆。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        let gap = Date().timeIntervalSince(progressAt)
        progressAt = Date()
        if gap > 2 {
            AppLog.log("tts.progress at=\(characterRange.location)")
        }
    }
}

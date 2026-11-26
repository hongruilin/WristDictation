import Foundation
import Combine
import Darwin

#if os(watchOS)
import WatchKit
#endif

/// 听写引擎：播报次数、两种间隔、状态迁移、播放控制的唯一实现。
///
/// 约定：所有公开方法都在主线程调用，内部定时器与语音回调也统一回到主线程，
/// 因此不使用额外的锁。界面与耳机控制只向这里发命令，不直接操作 TTS 或计时器。
final class DictationEngine: ObservableObject {

    // MARK: 状态

    enum Phase: String {
        case idle
        case preparing
        case speaking
        case repeatWaiting
        case nextWordWaiting
        case waitingForAdvance
        case paused
        case completed
        case failed

        var label: String {
            switch self {
            case .idle: return "准备就绪"
            case .preparing: return "准备中"
            case .speaking: return "播报中"
            case .repeatWaiting: return "同词间隔"
            case .nextWordWaiting: return "下一词间隔"
            case .waitingForAdvance: return "等待中"
            case .paused: return "已暂停"
            case .completed: return "本轮完成"
            case .failed: return "出错了"
            }
        }

        var isRunning: Bool {
            switch self {
            case .speaking, .repeatWaiting, .nextWordWaiting, .waitingForAdvance, .preparing:
                return true
            default:
                return false
            }
        }
    }

    private enum WaitPurpose {
        case repeatAgain
        case nextWord
    }

    // MARK: 对外状态

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var libraryName: String = ""
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var currentRepeat: Int = 0
    @Published private(set) var currentRepeatTarget: Int = 1
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var playedItems: [PlayedItem] = []
    /// 上一轮结果。退出听写页后仍可从首页回看（PRD 7.4）。
    @Published private(set) var lastAnswerSheet: AnswerSheet?
    @Published private(set) var notice: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsedText: String = "00:00"

    /// 长按偷看用：只有用户主动长按时界面才读取它。
    var peekText: String? {
        guard phase != .idle, phase != .completed, currentIndex < queue.count else { return nil }
        return queue[currentIndex].text
    }

    var progressText: String {
        guard totalCount > 0 else { return "0 / 0" }
        return "\(min(currentIndex + 1, totalCount)) / \(totalCount)"
    }

    var currentMode: PlaybackMode { library?.mode ?? .sequential }

    // MARK: 依赖

    private let speech: SpeechService
    private let audio: AudioSessionController
    private let remote: RemoteCommandBridge
    private let store: PlaybackStateStore

    // MARK: 内部状态

    private var library: WordLibrary?
    private var settings: AppSettings = .default
    private var queue: [VocabularyEntry] = []
    private var params: [ResolvedParameters] = []

    private var ticker: DispatchSourceTimer?
    private var pausedHeartbeat: DispatchSourceTimer?
    /// 播报看门狗：只在 `.speaking` 期间跑，0.5 秒问一次合成器还活着没。
    /// **间隔期它根本不存在**（`handleSpeechFinished` 第一件事就是停掉它），
    /// 所以 10 秒、20 秒乃至几分钟的间隔完全不受影响——不要用 `nextWordGap`
    /// 去调任何跟它有关的超时值，两者是不同时间轴上的东西。
    private var speechWatchdog: DispatchSourceTimer?
    private var speechMissCount = 0
    /// 本次开口的时刻，用于在日志里区分"等了多久"。
    private var speechStartedAt = Date.distantPast
    /// 从 `speak()` 到 `didStart` 的容忍上限。
    ///
    /// **这个值与「播报间隔」完全无关，不要拿它去比 `nextWordGap`。**
    /// 计时器每次 `beginSpeaking()` 都从 0 开始，只覆盖"这一句话从下命令
    /// 到真的出声"的那一小段。间隔 20 秒还是 5 分钟，都发生在计时器启动之前。
    ///
    /// 取 12 秒是因为间隔久了语音引擎可能已被系统换出、需要重新加载语音包。
    /// 宁可多等几秒，也不要误判跳词——跳词是**静默错误**，用户根本不知道
    /// 漏了一个词；而卡住是可见的，用户会按下一首或暂停。
    private static let speechStartTimeout: TimeInterval = 12
    /// 连续多少次"看门狗兜底"。真回调一到就清零；连续 3 次说明语音整条链路坏了
    /// （没音频路由、语音包损坏），继续兜底会把整个词库一路空跳完，
    /// 所以到 3 次就停下来暂停，让用户看见。
    private var stallRecoveryCount = 0
    /// `didCancel(unexpected)` 的连击计数：合成器自己放弃开口。
    /// 连续三次（每次都在开口后 0.6 秒内被丢掉）就说明输出链路是死的。
    private var cancelStreak = 0
    /// 是否已经切到"合成器自带会话"的兼容模式。
    private var compatMode = false
    /// 这一轮暂停是不是"退到后台"自动造成的。只有自动暂停才在回前台时自动恢复，
    /// 用户自己按的暂停不会被这条路径悄悄推翻。
    private var autoPausedForBackground = false
    private var deadline: Date?
    private var waitPurpose: WaitPurpose?
    private var utteranceToken: UUID?
    private var pausedFrom: Phase = .speaking
    private var remainingAtPause: TimeInterval?
    private var lastSaveAt = Date.distantPast
    private var lastTickAt = Date()
    private var lastNowPlayingReassertAt = Date.distantPast
    private var playRecordIndex: [Int: Int] = [:]
    /// 本轮是否开启了省电模式（来自手机端设置，本轮开始时取值）。
    private var powerSaving = false

    // MARK: 初始化

    init(speech: SpeechService = SystemSpeechService(),
         audio: AudioSessionController = AudioSessionController(),
         remote: RemoteCommandBridge = RemoteCommandBridge(),
         store: PlaybackStateStore = .shared) {
        self.speech = speech
        self.audio = audio
        self.remote = remote
        self.store = store

        self.speech.onFinish = { [weak self] token in
            DispatchQueue.main.async {
                // 真回调来了说明语音链路是通的，清零看门狗的连续失败计数
                self?.stallRecoveryCount = 0
                self?.cancelStreak = 0
                self?.handleSpeechFinished(token)
            }
        }
        self.speech.onCancel = { [weak self] token in
            DispatchQueue.main.async { self?.handleSpeechCancelled(token) }
        }
        bindRemoteCommands()

        // 音频会话反复激活不起来时，**停下来告诉用户**，不要继续静默播。
        //
        // 2026-11-20 实测：会话被系统持续打断（`interruption began` 809 条、
        // `ended` 零条），`setActive` 连续失败，但 `AVSpeechSynthesizer` 在没有
        // 输出路由的会话上照常回调 `didFinish`——状态机一路推进、进度条一直走，
        // 用户却听不到任何声音。这种"看起来在播、其实没出声"是最难自查的失败，
        // 宁可打断这一轮，也不能让它默默跑完 50 个词。
        audio.onPersistentActivationFailure = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.phase != .paused, self.phase != .idle,
                      self.phase != .completed else { return }
                AppLog.log("engine.audioUnavailable 连续激活失败")
                // 先试最后一条出声的路：放弃自有会话，让合成器自己发声。
                if self.enterCompatibilityModeIfNeeded(reason: "activate") { return }
                self.notice = "音频被占用，已暂停。请重启手表后重试"
                self.pause()
            }
        }

        // 自有会话刚建立就被系统收走 / 耳机掉了：**当场**降级，不攒失败次数。
        //
        // 原来要等 3 次激活失败加指数退避（2/4/8 秒）才降级，用户听到的是
        // "第一个词哑、后面几个也哑，全得自己推"。第一次打断就已经证明这条路
        // 走不通了，没有理由再等。
        audio.onSessionLost = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                switch self.phase {
                case .preparing, .speaking, .repeatWaiting, .nextWordWaiting, .waitingForAdvance:
                    break
                case .idle, .paused, .completed, .failed:
                    return
                }
                AppLog.log("engine.sessionLost 立刻降级 phase=\(self.phase.rawValue)")
                // 只有"正在念的词已经哑了"才需要重播；等待间隙降级直接换引擎，
                // 别取消倒计时打扰节奏。
                _ = self.enterCompatibilityModeIfNeeded(reason: "sessionLost",
                                                        replay: self.phase == .speaking)
            }
        }
    }

    private func bindRemoteCommands() {
        remote.onTransport = { [weak self] intent in self?.handleTransport(intent) }
        remote.onNext = { [weak self] in self?.next() }
        remote.onPrevious = { [weak self] in self?.previous() }
    }

    /// 播放/暂停命令的状态驱动处理。
    ///
    /// 关键事实：本 App 在"暂停"期间**仍然在渲染那条静音循环轨**，所以系统
    /// 自始至终把我们当作"正在播放"的设备。AirPods 每次单击投递过来的都是
    /// `pause`（或 `toggle`），几乎不会投递 `play`。
    ///
    /// V1.4 的写法是 `remote.onPause = { pause() }`，而 `pause()` 开头有
    /// `guard phase != .paused else { return }`——暂停之后再按，命令到达却被
    /// 直接丢掉，用户就永远按不回来了。这就是 V1.5 修掉的问题。
    ///
    /// 现在改成看状态而不是看命令名：处于暂停就恢复，处于运行就暂停。
    /// 代价是"命令名"信息被弱化，但换来的是无论系统发 play / pause / toggle
    /// 中的哪一个，按键行为都符合直觉。
    private func handleTransport(_ intent: TransportIntent) {
        switch phase {
        case .paused:
            AppLog.log("transport.resume intent=\(intent.rawValue)")
            resume()

        case .speaking, .repeatWaiting, .nextWordWaiting, .waitingForAdvance, .preparing:
            if intent == .play {
                // 系统认为我们已暂停、实际还在跑：不动播报，只把 Now Playing 纠正回来。
                // 这种不一致通常出现在路由刚切换完，属于噪音，不该被当成用户操作。
                AppLog.log("transport.play ignored (running)")
                refreshNowPlaying(isPlaying: true)
            } else {
                AppLog.log("transport.pause intent=\(intent.rawValue)")
                pause()
            }

        case .idle, .completed, .failed:
            AppLog.log("transport.ignored phase=\(phase.rawValue) intent=\(intent.rawValue)")
        }
    }

    // MARK: 开始

    func start(library: WordLibrary, settings: AppSettings, resume snapshot: SessionSnapshot? = nil) {
        guard library.enabledCount > 0 else {
            phase = .failed
            notice = "词库里没有启用的词条"
            AppLog.log("engine.start blocked: empty library")
            return
        }

        self.library = library
        self.settings = settings
        self.powerSaving = settings.powerSaving
        self.libraryName = library.name
        self.notice = nil
        self.playedItems = []
        self.playRecordIndex = [:]
        self.autoPausedForBackground = false
        self.stallRecoveryCount = 0
        self.cancelStreak = 0
        stopSpeechWatchdog()
        // 音频路径：按**当前音频路由**决定这一轮走哪条。
        //
        // 三条规则（详见 AudioSessionController.shouldUseMainSession）：
        //   用户强制后台保活 → 主模式
        //   有耳机           → 主模式（耳机键只有戴耳机才有意义，A2DP 是独立链路）
        //   外放             → 兼容模式（没有耳机时耳机键本来无用，声音优先）
        //
        // 原来的写法是无条件 `leaveCompatibilityMode()`，于是每一轮都重新掉进
        // 同一个坑：头几个词静音、用户手动推、攒够失败才降级。
        let useMainSession = audio.shouldUseMainSession
        AppLog.log("engine.audioRoute headphone=\(audio.isHeadphoneRoute) "
                   + "mainSession=\(useMainSession) route=\(audio.routeDescription)")
        if useMainSession {
            if compatMode {
                // 戴上耳机了（或用户主动要了后台保活），回主模式。
                compatMode = false
                audio.leaveCompatibilityMode()
                speech.setUsesApplicationAudioSession(true)
            }
        } else if !compatMode {
            compatMode = true
            speech.setUsesApplicationAudioSession(false)
            audio.enterCompatibilityMode(reason: "speaker")
        }
        // 新一轮开始，上一轮答案不再保留（PRD 7.4）
        self.lastAnswerSheet = nil

        let enabled = library.enabledEntries

        if let snapshot, let restored = restoreQueue(from: snapshot, enabled: enabled) {
            queue = restored
            currentIndex = min(max(0, snapshot.currentIndex), max(0, queue.count - 1))
            // 快照里的 `currentIndex` 在"等待下一词"阶段仍指向**刚播完**的那个词——
            // 索引 +1 是在 `fireWait()` 里做的，而 `pause()`/`stop()` 都发生在它之前。
            // 直接按原值恢复会把刚念过的词再念一遍，断点续播的预期是"接着下一个"。
            // 注意 `.repeatWaiting` 不能 +1：那个阶段当前词还没念够次数。
            if let saved = Phase(rawValue: snapshot.phaseRaw),
               saved == .nextWordWaiting || saved == .waitingForAdvance {
                currentIndex = min(currentIndex + 1, queue.count)
            }
            currentRepeat = 0
            playedItems = snapshot.playedItems
            for (i, item) in playedItems.enumerated() {
                if let idx = queue.firstIndex(where: { $0.text == item.text }) {
                    playRecordIndex[idx] = i
                }
            }
            startedAt = snapshot.startedAt
            AppLog.log("engine.resume index=\(currentIndex+1)/\(queue.count)")
        } else {
            queue = library.mode == .shuffle ? enabled.shuffled() : enabled
            currentIndex = 0
            currentRepeat = 0
            startedAt = Date()
            AppLog.log("engine.start library=\(library.name) count=\(queue.count) mode=\(library.mode.rawValue) powerSaving=\(powerSaving)")
        }

        // 随机模式只影响 queue 的顺序（上面已经洗好牌），
        // 单条参数照常解析——每词该播几次就播几次。
        params = queue.map {
            ParameterResolver.resolve(settings: settings, library: library, entry: $0)
        }
        totalCount = queue.count
        phase = .preparing

        audio.activate()
        audio.beginExtendedRuntime(onWillExpire: { [weak self] in
            DispatchQueue.main.async { self?.handleRuntimeWillExpire() }
        }, onInvalidated: { [weak self] reason in
            DispatchQueue.main.async { self?.handleRuntimeInvalidated(reason) }
        })
        remote.activate()

        refreshNowPlaying(isPlaying: true)
        saveSnapshot(force: true)
        if let level = batteryPercent() {
            AppLog.log("power start battery=\(level)% items=\(queue.count)")
        }
        beginSpeaking()
    }

    private func restoreQueue(from snapshot: SessionSnapshot, enabled: [VocabularyEntry]) -> [VocabularyEntry]? {
        guard snapshot.libraryID == library?.id else { return nil }
        let map = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        var restored: [VocabularyEntry] = []
        for id in snapshot.queueEntryIDs {
            guard let entry = map[id] else { return nil }
            restored.append(entry)
        }
        guard !restored.isEmpty else { return nil }
        return restored
    }

    // MARK: 播报

    private func beginSpeaking() {
        guard currentIndex < queue.count else {
            finish()
            return
        }
        let entry = queue[currentIndex]
        let target = max(1, params[currentIndex].repeatCount)
        currentRepeatTarget = target
        currentRepeat += 1

        phase = .speaking
        remaining = nil
        deadline = nil
        lastTickAt = Date()

        // 每次开口前确认会话与静音轨都还在。暂停恢复、切词、长间隔之后的第一次
        // 播报最容易静音，这里补一刀，失败会走 activate() 全量重建。
        audio.ensureActive()

        let token = speech.speak(entry.text,
                                 rate: Float(settings.speechRate),
                                 voiceIdentifier: settings.voiceIdentifier)
        utteranceToken = token
        startSpeechWatchdog()
        recordPlay(entry)

        refreshNowPlaying(isPlaying: true)
        updateElapsed()
        saveSnapshot(force: true)
        AppLog.log("speak idx=\(currentIndex+1) repeat=\(currentRepeat)/\(target)")
    }

    private func handleSpeechFinished(_ token: UUID) {
        guard phase == .speaking, token == utteranceToken else {
            AppLog.log("finish ignored stale=\(token.uuidString.prefix(8))")
            return
        }
        stopSpeechWatchdog()
        utteranceToken = nil

        let param = params[currentIndex]

        if currentRepeat < currentRepeatTarget {
            beginWait(param.sameWordGap, purpose: .repeatAgain)
            return
        }

        if currentIndex >= queue.count - 1 {
            finish()
            return
        }

        if param.isManualAdvance {
            waitPurpose = nil
            deadline = nil
            remaining = nil
            phase = .waitingForAdvance
            refreshNowPlaying(isPlaying: true)
            saveSnapshot(force: true)
        } else {
            beginWait(param.nextWordGap, purpose: .nextWord)
        }
    }

    /// 合成器**自己**把这次开口丢掉了（不是我们按暂停）。
    ///
    /// 没有可用输出路由时它就是这个形态：不 `didStart`、不 `didFinish`，
    /// 直接 `didCancel`。原来的实现只记一行日志就什么都不做，于是状态机
    /// 永远停在 `.speaking`——界面不动、也不报错。现在把它当成"这次开口结束了"，
    /// 但同时计数：连续三次说明整条输出链路是死的，停下来告诉用户。
    private func handleSpeechCancelled(_ token: UUID) {
        guard phase == .speaking, token == utteranceToken else { return }
        stopSpeechWatchdog()
        utteranceToken = nil

        let elapsed = Date().timeIntervalSince(speechStartedAt)
        if elapsed < 0.6 { cancelStreak += 1 } else { cancelStreak = 0 }
        AppLog.log("tts.cancelled live=\(cancelStreak) elapsed=\(String(format: "%.2f", elapsed))")

        if cancelStreak >= 3 {
            cancelStreak = 0
            if enterCompatibilityModeIfNeeded(reason: "cancel") { return }
            AppLog.log("engine.audioUnavailable 连续取消 → 暂停并提示")
            notice = "音频输出异常，已暂停。请重启手表后重试"
            pause()
            return
        }
        handleSpeechFinished(token)
    }

    /// 放弃自有音频会话，改用合成器自己的会话继续播。
    ///
    /// 只在"确认没有声音"时调用，且**一轮只调一次**。成功后这一轮会失去
    /// Now Playing（耳机键失效），但至少能听见词——比整轮静音有价值得多。
    ///
    /// - Parameter replay: 是否把当前词重播一遍。正在念的那个词已经哑了，必须重播；
    ///   而在等待间隙降级时不必打断节奏——`pause()` + `resume()` 会取消倒计时
    ///   并把进度往回退，反而更吵。
    @discardableResult
    private func enterCompatibilityModeIfNeeded(reason: String, replay: Bool = true) -> Bool {
        guard !compatMode else { return false }
        compatMode = true
        AppLog.log("engine.compatMode reason=\(reason) 放弃 Now Playing 换回声音")
        speech.setUsesApplicationAudioSession(false)
        audio.enterCompatibilityMode()
        notice = "音频会话异常，已切换兼容模式（耳机键暂不可用）"
        if replay {
            // 复用已有的"整词重播"路径：pause() 会把 currentRepeat 退回去，
            // 恢复时不会多算一次重复。
            pause()
            resume()
        }
        return true
    }

    // MARK: 等待与计时

    private func beginWait(_ seconds: TimeInterval, purpose: WaitPurpose) {
        waitPurpose = purpose
        phase = purpose == .repeatAgain ? .repeatWaiting : .nextWordWaiting

        if seconds <= 0.001 {
            deadline = nil
            remaining = nil
            fireWait()
            return
        }

        deadline = Date().addingTimeInterval(seconds)
        remaining = seconds
        startTicker()
        // 间隙里也声明"在播放"。会话本身没有停，只是暂时不出声；
        // 如果这里报 false，系统会认为我们已经暂停，耳机按键就不再转发。
        refreshNowPlaying(isPlaying: true)
        saveSnapshot(force: true)

        // 省电模式：空档期停掉静音轨。整个听写里空档占的时间远多于念词，
        // 这一停才是真正把音频管线与蓝牙从"持续流式"里解放出来的地方。
        // 代价写在 AudioSessionController.pauseKeepAlive 的注释里。
        if powerSaving {
            audio.pauseKeepAlive()
        }
    }

    private func startTicker() {
        ticker?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 0.2 秒（原来是 0.1 秒）。倒计时按 0.1 秒显示，0.2 秒的采样误差看不出来，
        // 但每秒的 CPU 唤醒从 10 次降到 5 次——熄屏后这类周期性唤醒会一直把 SoC
        // 从低功耗态拽出来，一轮 15 分钟就是 4500 次。
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: 播报看门狗

    /// `AVSpeechSynthesizer` 有一种静默失败：回调了 `didStart`，但既不出声
    /// 也不回调 `didFinish`。实测触发路径是**在后台开口**——
    /// 00:58:12 按表冠退到后台，00:58:15 定时器照常触发 `speak`，
    /// `tts.didStart 91D17FAF` 之后三分钟没有任何回调，状态机卡在 `.speaking`，
    /// 界面显示"播放中"却没有声音，也不会自己往下走。
    ///
    /// 这里每 0.5 秒问一次合成器，但**只在"一个词正在播"的区间里问**：
    /// `beginSpeaking()` 启动、`handleSpeechFinished()` 第一行停掉。
    /// 词与词之间的间隔（`.nextWordWaiting` / `.repeatWaiting` /
    /// `.waitingForAdvance`）由 0.2 秒的 ticker 独家负责倒计时，看门狗不在场，
    /// 间隔设成 15 秒还是 5 分钟都一样。
    ///
    /// 判定分两段，因为"合成器不吭声"有两种完全不同的成因：
    ///
    /// 1. **还没收到 `didStart`**（`speech.didStartCurrent == false`）：
    ///    系统还在加载语音包 / 排队占用音频路由，`isSpeaking` 为假是正常的。
    ///    这一段**不计 miss**，只跑一个 12 秒总超时——真超时才说明引擎起不来。
    ///    原来的写法在这段也照数 miss，靠"2 秒够长了吧"来对冲冷启动，
    ///    属于拿时间赌概率，冷启动慢一点就会误判跳词。
    /// 2. **已经 `didStart` 之后连续 4 次（2 秒）`isSpeaking == false`**：
    ///    开口了却既不推进也不回调，这才是后台播报那个真病的形态。
    private func startSpeechWatchdog() {
        speechWatchdog?.cancel()
        speechMissCount = 0
        speechStartedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // 兜底：间隔期 / 已暂停 / 已换词时残留的定时事件一律自灭。
            guard self.phase == .speaking, let token = self.utteranceToken else {
                self.stopSpeechWatchdog()
                return
            }
            let elapsed = Date().timeIntervalSince(self.speechStartedAt)

            // 第一段：还没开口。这段的 isSpeaking == false 不代表任何问题。
            if !self.speech.didStartCurrent {
                if elapsed >= Self.speechStartTimeout {
                    self.recoverStalledSpeech(token,
                                              reason: "no-start elapsed=\(String(format: "%.1f", elapsed))")
                }
                return
            }

            // 第二段：已开口。这里的 false 才是"亮了灯不出声"。
            if self.speech.isSpeaking {
                self.speechMissCount = 0
                // 第二段之二：合成器**说自己**还在播，但已经很久没有任何推进。
                //
                // 这是 V1.6.6 及之前完全没覆盖的盲区：音频单元卡死时
                // `isSpeaking` 永远为真，而 `didFinish` 永远不来。2026-11-25
                // 实测第一开口卡了 14 秒以上，界面停在第一个词不动，
                // 用户只能手动按下一首。判据换成"有没有进展"就不再看它的自述。
                let sinceProgress = Date().timeIntervalSince(self.speech.lastProgressAt)
                if sinceProgress >= self.speechProgressTimeout() {
                    self.recoverStalledSpeech(token,
                        reason: "no-progress since=\(String(format: "%.1f", sinceProgress))")
                }
                return
            }
            self.speechMissCount += 1
            if self.speechMissCount >= 4 {
                self.recoverStalledSpeech(token,
                                          reason: "silent elapsed=\(String(format: "%.1f", elapsed))")
            }
        }
        timer.resume()
        speechWatchdog = timer
    }

    /// 允许"开口之后多久完全没有推进"。
    ///
    /// 只在 `willSpeakRange` 一点都没回调时才计时，正常朗读秒级就有进展，
    /// 所以这个阈值不会误伤慢速朗读，只用来抓"卡死不往前走"。
    /// 词条本身很短（大多 1~4 字），长词按 1.5 秒/字补余量。
    private func speechProgressTimeout() -> TimeInterval {
        let chars = queue.indices.contains(currentIndex)
            ? Double(queue[currentIndex].text.count) : 2
        return 12 + max(0, chars - 4) * 1.5
    }

    /// 看门狗判定合成器已死时的统一善后。
    ///
    /// 连续 3 次兜底就停下来暂停：说明整条语音链路坏了（没有音频路由、
    /// 语音包损坏），继续兜底等于把整个词库一路空跳完，用户什么也不会听到。
    /// 第一次先尝试切兼容模式（合成器自带会话），成了这一轮还能继续听。
    private func recoverStalledSpeech(_ token: UUID, reason: String) {
        stopSpeechWatchdog()
        stallRecoveryCount += 1
        if stallRecoveryCount == 1, !compatMode {
            AppLog.log("tts.stalled \(reason) → 切换兼容模式重试")
            if enterCompatibilityModeIfNeeded(reason: "stalled") { return }
        }
        if stallRecoveryCount >= 3 {
            AppLog.log("tts.stalled \(reason) 连续 3 次，判定语音不可用 → 暂停")
            notice = "语音无法播放，已暂停"
            pause()
            return
        }
        AppLog.log("tts.stalled \(reason) 合成器已停但不回调 done → 按播完处理")
        handleSpeechFinished(token)
    }

    private func stopSpeechWatchdog() {
        speechWatchdog?.cancel()
        speechWatchdog = nil
        speechMissCount = 0
    }

    /// 暂停期间的低频心跳（5 秒一次）。
    ///
    /// 暂停时 ticker 是停的，没人再重设 Now Playing。系统一旦把 nowPlayingInfo
    /// 清掉（长暂停、路由变化都常见），本 App 就不再是 Now Playing，
    /// 耳机命令彻底断流——用户按什么都不会有反应。这条心跳只做两件很轻的事：
    /// 确认静音轨还在播、把 Now Playing 重写回去。
    private func startPausedHeartbeat() {
        // 省电模式下暂停期间本来就没有音频在渲染，系统那边也没有 Now Playing
        // 需要维护，心跳纯属多余；反过来把静音轨停掉才是这个模式的意义。
        guard !powerSaving else {
            stopPausedHeartbeat()
            audio.pauseKeepAlive()
            return
        }
        stopPausedHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.phase == .paused else { return }
            self.audio.ensureKeepAlive()
            self.remote.reassertNowPlaying()
        }
        timer.resume()
        pausedHeartbeat = timer
    }

    private func stopPausedHeartbeat() {
        pausedHeartbeat?.cancel()
        pausedHeartbeat = nil
    }

    private func tick() {
        guard let deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            stopTicker()
            fireWait()
        } else {
            // 只在"显示出来的数字真的会变"时才写 @Published。
            //
            // `remaining` 和 `elapsedText` 都是驱动 SwiftUI 的属性，每赋值一次就要
            // 走一遍视图比较。原来 10Hz 无条件赋值，等于熄屏状态下每秒做 10 次
            // 完全无效的视图更新——这部分 CPU 白烧，且让 SoC 更难进入低功耗态。
            // 现在倒计时按 0.1 秒取整、跳过重复值，实际更新频率降到约 5Hz。
            let shown = (left * 10).rounded(.up) / 10
            if shown != remaining {
                remaining = shown
            }
            updateElapsed()
            // 静音轨可能被 TTS 抢占或系统打断，这里低成本复查一次。
            // `ensureKeepAlive` 只是读一个本地属性，可以高频调。
            // 省电模式下这个空档本来就没有音频在渲染，不能在这里把它复活，
            // 否则等于白关。
            if !powerSaving {
                audio.ensureKeepAlive()
            }

            // Now Playing 绝不能跟着 0.1 秒的节拍重写。
            // 每写一次都是一趟到 mediaremoted 的跨进程调用，10Hz 的写入会把那个
            // 守护进程拖住（本机日志里它 23:50 崩过一次），主线程随之卡死，
            // 随后被 watchdog 强杀——表现是"播着播着自己退出"，且不留 crash log。
            // 5 秒一次足够覆盖"信息被系统清空"这种情况。
            let now = Date()
            if now.timeIntervalSince(lastNowPlayingReassertAt) >= 5 {
                lastNowPlayingReassertAt = now
                remote.reassertNowPlaying()
            }
        }
    }

    private func fireWait() {
        let purpose = waitPurpose
        waitPurpose = nil
        deadline = nil
        remaining = nil

        switch purpose {
        case .repeatAgain:
            beginSpeaking()
        case .nextWord:
            currentIndex += 1
            currentRepeat = 0
            beginSpeaking()
        case .none:
            break
        }
    }

    /// 从后台/挂起回来时补一次已过期的等待。
    ///
    /// 专为省电模式准备：空档期没有音频在渲染，watchOS 可能把进程挂起，
    /// 那时 `tick` 不会跑，倒计时看起来就"卡在某个词"。抬腕回到前台时
    /// 调这里，只要截止时间过了就立刻补一次，状态机继续往下走。
    /// 省电模式关闭时这一步通常什么都不做（计时器一直在正常跑）。
    func catchUpIfNeeded() {
        guard phase == .repeatWaiting || phase == .nextWordWaiting else { return }
        guard let deadline, deadline.timeIntervalSinceNow <= 0 else { return }
        stopTicker()
        AppLog.log("engine.catchUp 补上一次已过期的等待")
        fireWait()
    }

    private func updateElapsed() {
        guard let startedAt else {
            if elapsedText != "00:00" { elapsedText = "00:00" }
            return
        }
        let total = Int(Date().timeIntervalSince(startedAt))
        let text = String(format: "%02d:%02d", total / 60, total % 60)
        // 分钟级文本没必要每秒重写十次——它一分钟才变一次。
        if text != elapsedText {
            elapsedText = text
        }
    }

    // MARK: 控制

    /// 播放/暂停键的统一入口——**屏幕点击和双指互点都走这里**。
    ///
    /// `handGestureShortcut` 的语义就是"替我按下这个按钮"，两条输入共用同一个
    /// button action，所以在日志里也分不出是谁触发的（都记 `gesture.command`）。
    ///
    /// 故意**不**直接调 `togglePlayPause()`：表盘双击和耳机按键是同一个语义，
    /// 走同一条 `handleTransport` 状态机才能共享去抖（0.5s）。
    /// 否则 App 作为 Now Playing 应用，一次双击可能被系统同时派发手势与媒体命令，
    /// 两条路径各翻一次状态，用户感知就是"按了没反应"。
    func handleDoubleTap() {
        remote.gestureTransport(.toggle)
    }

    func togglePlayPause() {
        switch phase {
        case .paused:
            resume()
        case .speaking, .repeatWaiting, .nextWordWaiting, .waitingForAdvance, .preparing:
            pause()
        case .idle, .completed, .failed:
            break
        }
    }

    func pause() {
        guard phase != .paused else { return }

        stopSpeechWatchdog()

        switch phase {
        case .speaking:
            pausedFrom = .speaking
            speech.stop()
            utteranceToken = nil
            // 这一次已经计过数，恢复时整词重播，所以先退回去
            currentRepeat = max(0, currentRepeat - 1)
            remainingAtPause = nil
        case .repeatWaiting, .nextWordWaiting:
            pausedFrom = phase
            remainingAtPause = deadline?.timeIntervalSinceNow ?? 0
            stopTicker()
            deadline = nil
        case .waitingForAdvance:
            pausedFrom = .waitingForAdvance
            remainingAtPause = nil
        case .preparing:
            pausedFrom = .speaking
            remainingAtPause = nil
        default:
            return
        }

        phase = .paused
        remaining = nil
        refreshNowPlaying(isPlaying: false)
        saveSnapshot(force: true)
        startPausedHeartbeat()
        AppLog.log("pause from=\(pausedFrom.rawValue)")
    }

    // MARK: 前后台

    /// 退到后台（按表冠回表盘 / 切换 App）时暂停。
    ///
    /// **为什么不是"继续播"**：实测 `AVSpeechSynthesizer` 在后台开口只回调
    /// `didStart`，既不渲染声音也不回调 `didFinish`——00:58:15 那一轮卡了
    /// 三分多钟，界面一直显示"播放中"。这是合成器在后台拿不到渲染资源，
    /// 不是我们的状态机写错了。所以正确做法是诚实地暂停、保留进度，
    /// 而不是让界面骗人。
    func pauseForBackground() {
        guard phase != .paused, phase != .idle, phase != .completed else { return }
        AppLog.log("engine.backgroundPause phase=\(phase.rawValue)")
        // 后台很可能把音频会话悄悄收走了，标脏。回来开口时会真正重激活一次，
        // 否则合成器可能又在一个失效会话上"假播"。
        audio.invalidateSessionState()
        pause()
        autoPausedForBackground = true
    }

    /// 回到前台时，把"因退到后台而自动暂停"的那一次接回去。
    /// 用户自己按的暂停不会被这条路径推翻——那个标志只在 pauseForBackground 里置位。
    func resumeIfAutoPaused() {
        guard autoPausedForBackground else { return }
        autoPausedForBackground = false
        guard phase == .paused else { return }
        AppLog.log("engine.backgroundResume")
        resume()
    }

    func resume() {
        guard phase == .paused else { return }

        stopPausedHeartbeat()

        switch pausedFrom {
        case .speaking:
            // 会话可能在暂停期间被系统回收（AirPods 重连、被别的 App 抢过），
            // beginSpeaking 里会再确认一次，那里是唯一开口点，失败会全量重建。
            beginSpeaking()
        case .repeatWaiting:
            beginWait(remainingAtPause ?? 0, purpose: .repeatAgain)
        case .nextWordWaiting:
            beginWait(remainingAtPause ?? 0, purpose: .nextWord)
        case .waitingForAdvance:
            // 这条分支不开口播报，需要自己把会话拉回来
            audio.ensureActive()
            phase = .waitingForAdvance
            refreshNowPlaying(isPlaying: true)
            saveSnapshot(force: true)
        default:
            break
        }

        remainingAtPause = nil
        AppLog.log("resume from=\(pausedFrom.rawValue)")
    }

    func next() {
        guard phase != .idle, phase != .completed, phase != .failed else { return }
        let wasPaused = phase == .paused

        cancelCurrentActivity()

        if currentIndex >= queue.count - 1 {
            finish()
            return
        }

        currentIndex += 1
        currentRepeat = 0
        notice = nil

        if wasPaused {
            pausedFrom = .speaking
            phase = .paused
            refreshNowPlaying(isPlaying: false)
            saveSnapshot(force: true)
            startPausedHeartbeat()
        } else {
            beginSpeaking()
        }
    }

    func previous() {
        guard phase != .idle, phase != .failed else { return }
        let wasPaused = phase == .paused || phase == .completed

        cancelCurrentActivity()

        if currentIndex > 0 {
            currentIndex -= 1
        } else {
            currentIndex = 0
        }
        currentRepeat = 0
        notice = nil

        if wasPaused {
            pausedFrom = .speaking
            phase = .paused
            refreshNowPlaying(isPlaying: false)
            saveSnapshot(force: true)
            startPausedHeartbeat()
        } else {
            beginSpeaking()
        }
    }

    /// 手动推进模式下，用户按下一条。
    func advanceManually() {
        guard phase == .waitingForAdvance else { return }
        cancelCurrentActivity()
        currentIndex += 1
        currentRepeat = 0
        if currentIndex >= queue.count {
            finish()
        } else {
            beginSpeaking()
        }
    }

    func stop() {
        let wasCompleted = phase == .completed

        // 中途退出也要留下答案单，否则用户不知道自己漏了哪些（PRD 7.4）
        if !wasCompleted {
            archiveAnswerSheet(isComplete: false)
        }

        cancelCurrentActivity()
        phase = .idle
        remaining = nil
        stopTicker()

        // **中途退出保留快照**，让首页能「继续上次」。
        //
        // 原来这里是 `store.clear()`，等于把"我先歇一下"当成"这一轮作废"。
        // 但用户按 × 的真实意图十次有九次是前者：练了几组、想回首页看一眼、
        // 或者临时有事——下次接着来是默认预期，从头再来才是意外。
        // 真要作废，首页有「放弃上次进度」，语义上更明确。
        //
        // 播完（finished）那条路不走这里：`finish()` 已经存了 isActive=false 的快照，
        // 到这里再存 active 会把"已完成"覆盖成"可续播"，所以用 wasCompleted 挡住。
        if !wasCompleted {
            saveSnapshot(active: true, force: true)
        }

        audio.endExtendedRuntime()
        audio.deactivate()
        remote.deactivate()
        playedItems = []
        playRecordIndex = [:]
        autoPausedForBackground = false
        AppLog.log("engine.stop keepSnapshot=\(!wasCompleted)")
    }

    private func cancelCurrentActivity() {
        stopSpeechWatchdog()
        speech.stop()
        utteranceToken = nil
        stopTicker()
        stopPausedHeartbeat()
        deadline = nil
        remaining = nil
        waitPurpose = nil
    }

    // MARK: 结束

    private func finish() {
        cancelCurrentActivity()
        phase = .completed
        archiveAnswerSheet(isComplete: true)
        audio.endExtendedRuntime()
        refreshNowPlaying(isPlaying: false)
        audio.deactivate()
        saveSnapshot(active: false, force: true)
        AppLog.log("engine.completed items=\(playedItems.count)")
        if let level = batteryPercent() {
            let minutes = startedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
            AppLog.log("power end battery=\(level)% minutes=\(minutes) items=\(playedItems.count)")
        }
    }

    /// 把本轮实际播报过的内容固化成答案单，退出界面后仍可回看。
    private func archiveAnswerSheet(isComplete: Bool) {
        guard !playedItems.isEmpty else { return }
        lastAnswerSheet = AnswerSheet(libraryName: libraryName,
                                      items: playedItems,
                                      elapsed: elapsedText,
                                      finishedAt: Date(),
                                      isComplete: isComplete)
    }

    // MARK: 记录与快照

    private func recordPlay(_ entry: VocabularyEntry) {
        if let existing = playRecordIndex[currentIndex] {
            playedItems[existing].plays += 1
        } else {
            let item = PlayedItem(order: playedItems.count + 1, text: entry.text, plays: 1)
            playedItems.append(item)
            playRecordIndex[currentIndex] = playedItems.count - 1
        }
        logMemorySample()
    }

    /// 每 10 条记一次常驻内存。
    ///
    /// watchOS 对后台 App 的内存上限很紧，超了会被 jetsam 直接杀掉，
    /// **不产生 crash log**，现象和"闪退"一模一样。留一条内存曲线，
    /// 下次再出现异常终止时能直接排除或确认这个方向。
    private func logMemorySample() {
        guard playedItems.count % 10 == 0 else { return }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let battery = batteryPercent().map { " battery=\($0)%" } ?? ""
        AppLog.log("mem rss=\(info.resident_size / 1_048_576)MB items=\(playedItems.count)\(battery)")
    }

    /// 电量百分比。取不到时返回 nil。
    ///
    /// 存在的意义是把"这玩意儿费不费电"变成一条可测的曲线：
    /// 每轮开始、每 10 条、每轮结束各记一次，配合 `startedAt` 就能算出
    /// 每小时掉电百分比，不用靠感觉。
    private func batteryPercent() -> Int? {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let level = device.batteryLevel  // 0...1，未知时为 -1
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
        #else
        return nil
        #endif
    }

    private func refreshNowPlaying(isPlaying: Bool) {
        let title = totalCount > 0 ? "\(libraryName) \(progressText)" : libraryName
        remote.updateNowPlaying(title: title, isPlaying: isPlaying, elapsed: 0)
    }

    private func saveSnapshot(active: Bool = true, force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastSaveAt) < 1.0 { return }
        lastSaveAt = now

        guard let library, !queue.isEmpty else { return }
        let snapshot = SessionSnapshot(
            libraryID: library.id,
            libraryName: library.name,
            mode: library.mode,
            queueEntryIDs: queue.map { $0.id },
            currentIndex: currentIndex,
            currentRepeat: currentRepeat,
            phaseRaw: phase.rawValue,
            remainingSeconds: remaining,
            playedItems: playedItems,
            startedAt: startedAt ?? now,
            updatedAt: now,
            isActive: active && phase != .completed
        )
        store.save(snapshot)
    }

    // MARK: 后台会话回调

    private func handleRuntimeWillExpire() {
        // 只记录，不提示。self-care 会话到期后音频保活依然有效，
        // 弹"建议分段练习"属于误报——用户实际体验是继续播报。
        AppLog.log("engine.runtimeWillExpire (audio keep-alive continues)")
    }

    private func handleRuntimeInvalidated(_ reason: String) {
        guard phase.isRunning || phase == .paused else { return }

        // 这里以前会调 pause()，是 V1.5 之前「放下手腕就自己停了」的根源。
        //
        // self-care 会话在「退到前台以外」时就会被系统撤销——放下手腕、屏幕熄灭
        // 都算，这是常态而不是异常。而进程真正的存活保障是 Watch-Info.plist 里
        // WKBackgroundModes 的 audio：静音循环轨一直在渲染音频，App 不会因为
        // 会话撤销而被挂起。所以这里只降级记录，绝不能打断播报。
        AppLog.log("engine.runtimeInvalidated \(reason) (audio keep-alive continues)")
    }

    // MARK: 估算

    /// 本轮预计时长（秒），用于"较长建议分段"的提示。
    static func estimateDuration(library: WordLibrary, settings: AppSettings) -> TimeInterval {
        ParameterResolver.estimateDuration(library: library, settings: settings)
    }
}

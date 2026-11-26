import Foundation
import AVFoundation

#if os(watchOS)
import WatchKit
#endif

/// 音频会话与后台存活。
///
/// 主方案：本轮开始时申请 ExtendedRuntimeSession（Info.plist 声明 self-care），
/// 该类型可提供约 1 小时的连续后台运行，正好覆盖 60 分钟长稳目标。
/// 若申请失败或权限不足，退回"仅在出声时保持活跃"的保守模式。
///
/// 关于耳机按键（2026-11-18 修正）：
/// watchOS 上"谁是 Now Playing"完全由音频会话决定——`MPNowPlayingInfoCenter.playbackState`
/// 在 watchOS 上是 `API_UNAVAILABLE`，`isNowPlayingCandidate` 也是 visionOS 专有。
/// 所以必须满足两个条件，系统才会把耳机命令转发给本 App：
///   1. 会话不是混音的（`.duckOthers` 会隐式打开 `.mixWithOthers`，见 SDK 注释）；
///   2. 会话在整个听写过程中持续有音频在渲染，而不是只在念词的那一两秒。
/// 条件 1 靠 setCategory 的 options 为空，条件 2 靠一条静音循环轨兜底。
final class AudioSessionController: NSObject {

    private var runtimeSession: WKExtendedRuntimeSession?
    private var onWillExpire: (() -> Void)?
    private var onInvalidated: ((String) -> Void)?

    /// 静音循环轨。它存在的唯一目的是让会话在整个听写过程中都处于"正在播放"，
    /// 从而在念词的间隙（3~10 秒）里仍然是系统的 Now Playing 应用。
    private var keepAlive: AVAudioPlayer?

    /// 会话是否已激活。自己维护而不是每次问系统：`setActive(true)` 是会阻塞的
    /// 跨进程调用，蓝牙链路上尤其慢。每词开口前都做一次，累积起来足以让主线程
    /// 卡顿到被 watchdog 盯上。
    private var sessionActive = false
    private var interruptionObserver: NSObjectProtocol?
    /// 路由变化单独观察。打断通知里看不出"是不是耳机掉了/切到扬声器"，
    /// 而这两件事在手表上足以让一次播报静音。
    private var routeObserver: NSObjectProtocol?

    /// 连续多少次"设激活"彻底失败。用来做两件事：
    /// ① 指数退避，别让 0.2 秒的 ticker 每秒撞五次系统；
    /// ② 到阈值时通知引擎停下来，而不是在没有输出路由的会话上静默播完一整轮。
    ///
    /// V1.6.5 之前的实测（2026-11-20 20:16）：音频会话被系统持续打断，
    /// `setActive(true)` 连续失败 21 次、`interruption began` 809 次且
    /// **一次 `ended` 都没有**。原来每 tick 都重试，结果每秒刷出 3~8 条
    /// `keepalive revived` + `interruption began`，一边空转耗电一边把日志撑爆，
    /// 而 TTS 在没有输出路由的会话上照常回调 `didFinish`——
    /// 用户看到的就是"进度条在走，但一点声音都没有"。
    private var activationFailures = 0
    private var nextActivationAttemptAt = Date.distantPast
    private var keepAliveFailures = 0
    private var nextKeepAliveAttemptAt = Date.distantPast

    /// 兼容模式：彻底放弃本 App 的音频会话，让合成器自带会话发声。
    ///
    /// 代价是失去 Now Playing、耳机键失效，换回来的是"真的有声音"。
    /// 启用后本类不再尝试任何 `setActive`、也不再建静音轨。
    private var compatMode = false
    var isCompatibilityMode: Bool { compatMode }

    // MARK: 播放引擎偏好

    /// 是否优先让合成器用自己的会话发声（即"兼容模式"）。
    ///
    /// **默认 true**。这不是保守的兜底，而是 2026-11-25 三次冷启动实测的结论——
    /// 三轮曲线一模一样，与操作无关：
    /// ```
    /// audio.activate ok route=Speaker
    /// audio.keepalive start ok=true / probe playing=true t=0.47
    /// +1.2s  audio.interruption began reason=0 other=false route=Speaker
    /// +10s   audio.reactivate failed code=561145203
    ///        audio.hardReset failed code=561145203   ← 硬重置也救不回来
    /// ```
    /// `-561145203` 就是 `!res`（资源不可用）。换句话说：`setActive(true)` 报成功是
    /// 假的，会话从没真正拿到输出路由；静音轨的 `currentTime` 照样在走（它跑在自己的
    /// 时钟上），TTS 也照样 `didStart`/走完内部时长——但一个字节都没送到扬声器。
    /// 而同一台设备、同一时刻切到兼容模式，`didStart`/`didFinish` 立刻成对出现。
    ///
    /// 所以"自有会话 + 静音保活轨"这条路在这台手表上已经被系统判死，App 侧
    /// 无论怎么重试、重置都拿不回来。默认必须走兼容模式，否则新用户第一次
    /// 用就是"有进度、没声音"。
    ///
    /// 手表设置里留了开关（「后台保活」），需要耳机键的用户可以打开去试——
    /// 万一某次系统重启后会话恢复了，那条路还是能用的。
    static let compatibilityKey = "wd.audio.compatibilityPreferred"

    static var prefersCompatibility: Bool {
        get {
            // 键不存在（全新安装 / 老版本升级）一律 true：默认先保证听得见。
            (UserDefaults.standard.object(forKey: compatibilityKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: compatibilityKey)
            AppLog.log("audio.prefersCompatibility=\(newValue ? "compat" : "main")")
        }
    }

    /// 连续激活失败达到阈值时回调。引擎会暂停并提示用户，
    /// **绝不静默把整个词库播完**——那是最难排查的一种失败。
    var onPersistentActivationFailure: (() -> Void)?

    /// 自有会话刚建立就被系统收走（或耳机掉了）时回调，**只报一次**。
    ///
    /// 存在的理由：`-561145203`（`!res`，硬件音频资源不足）出现后，
    /// 等它攒够 3 次失败 + 指数退避要走 10~30 秒，用户感受就是
    /// "第一个词没声音，得手动推好几个词才自动切过去"。
    /// 既然第一次打断就已经说明这条路不通，就该当场降级、当场重播这个词。
    var onSessionLost: (() -> Void)?
    /// 本次会话建立后是否已经报过 `onSessionLost`，避免几十条打断通知刷爆回调。
    private var reportedSessionLost = false

    /// 这一轮该不该用自有会话（主模式）。
    ///
    /// 三条规则，按优先级：
    /// 1. 用户在设置里打开「后台保活」→ 用主模式（他知情，愿意赌一次）。
    /// 2. **当前有耳机** → 用主模式。耳机键只在戴耳机时才有意义，而 A2DP 路由的
    ///    音频单元配置和扬声器完全不同——历史上耳机下这套是能工作的。
    /// 3. 外放 → 兼容模式。外放时耳机键本来就没用，没理由为了它牺牲声音。
    ///
    /// 这是 2026-11-25 的关键判断：`!res` 不是"权限被撤销"，而是"硬件音频资源
    /// 不足"。主模式下我们有静音轨、合成器也要开口，**两个音频消费者抢同一个
    /// 单元**；外放路由下音频单元只有一条，抢不到就 `!res`。耳机（A2DP）是独立
    /// 链路，两个消费者能共存。
    var shouldUseMainSession: Bool {
        !Self.prefersCompatibility || isHeadphoneRoute
    }

    var isRuntimeActive: Bool {
        runtimeSession?.state == .running
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    // MARK: 音频会话

    func activate() {
        // 兼容模式下不再碰会话：合成器用自己的，谁先 setActive 谁把对方顶掉。
        guard !compatMode else { return }
        observeInterruption()
        // 外放 + 没强制要后台保活 → 连 setCategory / setActive / 静音轨都不做。
        // 只要本 App 去申请会话，这台手表就会在 1~10 秒内把它判死（见
        // compatibilityKey 的注释），然后 TTS 全程无声。
        guard shouldUseMainSession else {
            enterCompatibilityMode(reason: "speaker")
            AppLog.log("audio.activate skipped（外放，走兼容模式）")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // 不能用 .duckOthers：SDK 明写 "Setting this option will also make your
            // session mixable with others (MixWithOthers will be set)"，而混音会话
            // 不会成为 Now Playing，耳机命令就永远收不到。
            // 而且 .duckOthers 只对 mode == .default 合法，配 .spokenAudio 属于无效组合。
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            sessionActive = true
            activationFailures = 0
            nextActivationAttemptAt = .distantPast
            reportedSessionLost = false
            let opts = session.categoryOptions.rawValue
            AppLog.log("audio.activate ok route=\(routeDescription) options=\(opts) "
                       + "headphone=\(isHeadphoneRoute)")
        } catch let error as NSError {
            sessionActive = false
            registerActivationFailure(error, phase: "activate")
        }
        startSilentKeepAlive()
    }

    /// 记一次激活失败：指数退避 + 到阈值通知引擎。
    /// 退避上限 30 秒——再久就等于放弃了，而音频会话确实有自行恢复的可能。
    private func registerActivationFailure(_ error: NSError, phase: String) {
        activationFailures += 1
        let delay = min(30.0, pow(2.0, Double(activationFailures)))
        nextActivationAttemptAt = Date().addingTimeInterval(delay)
        AppLog.log("audio.\(phase) failed code=\(error.code) domain=\(error.domain) "
                   + "count=\(activationFailures) retryIn=\(Int(delay))s "
                   + "other=\(AVAudioSession.sharedInstance().isOtherAudioPlaying) "
                   + "vol=\(String(format: "%.2f", AVAudioSession.sharedInstance().outputVolume)) "
                   + "route=\(routeDescription)")
        // 每满 3 次提醒一回：用户已经暂停过、又重新开始时，还有机会再被拦一次。
        if activationFailures >= 3, activationFailures % 3 == 0 {
            onPersistentActivationFailure?()
        }
    }

    func deactivate() {
        stopSilentKeepAlive()
        // 兼容模式下会话从来没归我们管，别去动它——一句多余的 setActive(false)
        // 会打断合成器正在用的那个自带会话。
        guard !compatMode else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        sessionActive = false
        AppLog.log("audio.deactivate")
    }

    /// 轻量校验：会话还 active、静音轨还在播。
    ///
    /// 暂停恢复、切词、长间隔之后的第一次播报最容易静音（会话可能被系统回收）。
    /// 但这里**不再无条件 `setActive(true)`**——那是个阻塞调用，原来每词调两次，
    /// 在蓝牙链路上足以把主线程拖到 watchdog 超时（表现为"按耳机就闪退"、
    /// 且不产生 crash log）。
    ///
    /// 现在只有确认掉线（打断通知把 `sessionActive` 置回 false）才真正重激活，
    /// 平时只做一次本地 `isPlaying` 判断，开销可忽略。
    /// 重激活本身带指数退避，见 `registerActivationFailure`。
    func ensureActive() {
        guard !compatMode else { return }
        if !sessionActive {
            guard Date() >= nextActivationAttemptAt else { return }
            guard reactivate() else { return }
        }
        if keepAlive == nil {
            startSilentKeepAlive()
        } else if let player = keepAlive, !player.isPlaying {
            reviveKeepAlive(player)
        }
    }

    /// 便宜的复活路径：直接 `setActive(true)`；不行再做一次硬重置。
    ///
    /// 硬重置（显式 `setActive(false)` → 重建 category → `setActive(true)`）
    /// 是"打断永不结束"这种僵尸状态的唯一出路。实测（2026-11-20）曾出现
    /// `interruption began` 收 809 条、`ended` **零条**，会话停在中间态，
    /// 此后每一次 `setActive(true)` 都失败——只有先显式关一次才能挣出来。
    @discardableResult
    private func reactivate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            sessionActive = true
            activationFailures = 0
            nextActivationAttemptAt = .distantPast
            AppLog.log("audio.reactivated")
            return true
        } catch let error as NSError {
            AppLog.log("audio.reactivate failed code=\(error.code)")
        }

        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        sessionActive = false
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            sessionActive = true
            activationFailures = 0
            nextActivationAttemptAt = .distantPast
            AppLog.log("audio.hardReset ok route=\(routeDescription)")
            return true
        } catch let error as NSError {
            registerActivationFailure(error, phase: "hardReset")
            return false
        }
    }

    /// 静音轨复活也要退避。它失败通常只是"会话没激活"的连带结果，
    /// 但在没有会话的情况下 `play()` 会立刻返回 false——0.2 秒一次就是纯空转。
    private func reviveKeepAlive(_ player: AVAudioPlayer) {
        guard Date() >= nextKeepAliveAttemptAt else { return }
        if player.play() {
            keepAliveFailures = 0
            nextKeepAliveAttemptAt = .distantPast
            AppLog.log("audio.keepalive revived")
        } else {
            keepAliveFailures += 1
            let delay = min(30.0, pow(2.0, Double(keepAliveFailures)))
            nextKeepAliveAttemptAt = Date().addingTimeInterval(delay)
            AppLog.log("audio.keepalive revive failed count=\(keepAliveFailures) "
                       + "retryIn=\(Int(delay))s")
        }
    }

    /// 退到后台时把会话状态**标脏**（不 deactivate）。
    ///
    /// watchOS 在 App 退到后台后会回收音频会话，但**不一定发打断通知**，
    /// 于是 `sessionActive` 还停在 true，回来时 `ensureActive()` 会跳过重激活，
    /// 合成器就在一个已经失效的会话上开口——正是"显示播放中却没声音"的成因之一。
    /// 这里只把标志置回 false，静音轨继续留着；下次开口由 `ensureActive()` 真正
    /// `setActive(true)`，失败会自动回落 `activate()` 全量重建。
    func invalidateSessionState() {
        guard sessionActive else { return }
        sessionActive = false
        AppLog.log("audio.session marked stale (background)")
    }

    /// 系统打断（来电、别的 App 抢音频）结束后把会话拉回来。
    /// 这是 `sessionActive` 唯一会变 false 的自动来源，别的场景不需要重激活。
    private func observeInterruption() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.sessionActive = false
                // 光记"开始了"没法归因。reason 区分：1=被别的 App 抢占、
                // 2=本 App 被系统挂起、4=内置麦克风被静音；suspended 是旧 API 的
                // 同一件事的前身；other 表示此刻是否有别的音频在响。
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
                let wasSuspended = note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false
                AppLog.log("audio.interruption began reason=\(reason) suspended=\(wasSuspended) "
                           + "other=\(AVAudioSession.sharedInstance().isOtherAudioPlaying) "
                           + "route=\(self.routeDescription)")
                // 主模式下**第一次**被打断就认输。
                // 这条路已经被系统判死（后续必然一路 `!res`），继续等 3 次失败
                // 加指数退避要走 10~30 秒，用户听到的就是"头几个词全是哑的、
                // 得自己手动推"。当场降级、当场把当前词重播一遍才是对的。
                if !self.compatMode, !self.reportedSessionLost {
                    self.reportedSessionLost = true
                    AppLog.log("audio.sessionLost 首次打断即降级")
                    self.onSessionLost?()
                }
            case .ended:
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                AppLog.log("audio.interruption ended options=\(options)")
                self.ensureActive()
            @unknown default:
                break
            }
        }
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let stillHeadphone = self.isHeadphoneRoute
            AppLog.log("audio.routeChange reason=\(reason) route=\(self.routeDescription) "
                       + "active=\(self.sessionActive) headphone=\(stillHeadphone)")
            // 主模式的前提是"有耳机"。耳机一掉 A2DP 链路就没了，音频单元回到
            // 外放那唯一一条，接着必然 `!res`。提前降级，别等它坏掉再兜。
            if !self.compatMode, !stillHeadphone, !self.reportedSessionLost {
                self.reportedSessionLost = true
                AppLog.log("audio.sessionLost 耳机断开即降级")
                self.onSessionLost?()
            }
        }
    }

    var routeDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.isEmpty { return "none" }
        return outputs.map { $0.portType.rawValue }.joined(separator: ",")
    }

    /// 是否走蓝牙/有线耳机。扬声器外放时听写体验差，需要提示。
    var isHeadphoneRoute: Bool {
        let types: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .airPlay]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { types.contains($0.portType) }
    }

    // MARK: 静音保持

    /// 会话在跑、但静音轨停了（被 TTS 抢占、被系统打断）时把它拉回来。
    /// 由引擎的计时器周期性调用（0.2 秒一次），成本是一次 `isPlaying` 判断。
    /// 真正要 `play()` 时走退避，不会每秒撞五次系统。
    func ensureKeepAlive() {
        guard runtimeSession != nil || keepAlive != nil else { return }
        guard let player = keepAlive else {
            startSilentKeepAlive()
            return
        }
        if !player.isPlaying {
            reviveKeepAlive(player)
        }
    }

    private func startSilentKeepAlive() {
        guard keepAlive == nil, !compatMode else { return }
        do {
            let player = try AVAudioPlayer(data: Self.silentWave())
            player.numberOfLoops = -1
            player.volume = 1.0
            player.prepareToPlay()
            let ok = player.play()
            keepAlive = player
            let session = AVAudioSession.sharedInstance()
            AppLog.log("audio.keepalive start ok=\(ok) vol=\(String(format: "%.2f", session.outputVolume)) "
                       + "sr=\(Int(session.sampleRate)) route=\(routeDescription)")
            // 0.5 秒后回看一次。`play()` 返回 true 只代表播放器**接受**了请求，
            // 不代表音频单元真的在拉数据。这里看 `currentTime` 有没有走：
            // 走了 = 渲染链路通；一直是 0 = 输出这条路根本没通，
            // 那么 TTS 不出声、`isSpeaking` 却为真的现象就有了统一解释。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak player] in
                guard let self, let player, self.keepAlive === player else { return }
                AppLog.log("audio.keepalive probe playing=\(player.isPlaying) "
                           + "t=\(String(format: "%.2f", player.currentTime)) route=\(self.routeDescription)")
            }
        } catch {
            AppLog.log("audio.keepalive failed: \(error.localizedDescription)")
        }
    }

    /// 退出兼容模式，下一轮重新走正常路径（`activate()` 会真正 setActive）。
    func leaveCompatibilityMode() {
        guard compatMode else { return }
        compatMode = false
        activationFailures = 0
        nextActivationAttemptAt = .distantPast
        keepAliveFailures = 0
        nextKeepAliveAttemptAt = .distantPast
        AppLog.log("audio.compatMode off 下一轮试回正常路径")
    }

    /// 进入兼容模式：把自有会话整个放掉，交给合成器自己发声。
    ///
    /// 这不是"优化"，是**唯一能出声的路**。启用后 Now Playing 随之中断、
    /// 耳机键失效——所以运行时降级时引擎必须给用户一句提示，不能悄悄降级；
    /// 而 "preferred"（用户在设置里就是选的这一档）不提示，那是正常状态。
    func enterCompatibilityMode(reason: String = "runtime") {
        guard !compatMode else { return }
        compatMode = true
        stopSilentKeepAlive()
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        sessionActive = false
        AppLog.log("audio.compatMode on reason=\(reason)（自有会话已放弃）")
    }

    private func stopSilentKeepAlive() {
        guard let player = keepAlive else { return }
        player.stop()
        keepAlive = nil
        AppLog.log("audio.keepalive stop")
    }

    /// 省电模式用：停掉静音循环轨，但保留会话本身。
    ///
    /// 静音数据量小得可以忽略（8kHz/16bit ≈ 16KB/s），真正贵的是"一直在渲染"
    /// 这件事本身——只要还有音频在渲染，A2DP 链路就维持在流式传输，射频与
    /// 编解码器都不休眠。所以想省电只有停渲染这一条路，调低采样率或音量都没用。
    ///
    /// 用 `pause()` 而不是 `stop()`：保留播放位置，恢复时能立刻续上。
    /// 会话不 deactivate：重开会触发路由重建，反而慢且吵。
    ///
    /// **调用方必须清楚代价**：没有音频在渲染 → 系统不再认为本 App 在播放 →
    /// 耳机键失效、熄屏后进程可能被挂起。默认路径永远不会调到这里。
    func pauseKeepAlive() {
        guard let player = keepAlive, player.isPlaying else { return }
        player.pause()
        AppLog.log("audio.keepalive paused（省电模式）")
    }

    /// 1 秒单声道 16bit 全零 WAV。内容是真的静音，不是把音量调 0，
    /// 这样会话才算"在渲染音频"，同时完全听不见。
    ///
    /// 采样率用 **44.1kHz**（原来 8kHz）。8kHz 需要由播放器做一次重采样，
    /// 在蓝牙链路上没问题，但内置扬声器这一路是否接受要打个问号——
    /// 2026-11-25 的故障形态是"会话 setActive 成功、静音轨 play() 返回 true，
    /// 但 TTS 从头到尾一声不响"，典型的重采样/音频单元起不来的样子。
    /// 44.1kHz 是硬件原生速率，不需要任何转换，只多占 80KB 内存。
    private static func silentWave(seconds: Double = 1.0, sampleRate: Int = 44100) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let dataSize = frames * 2
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))
        d.appendLE(UInt16(1))
        d.appendLE(UInt16(1))
        d.appendLE(UInt32(sampleRate))
        d.appendLE(UInt32(sampleRate * 2))
        d.appendLE(UInt16(2))
        d.appendLE(UInt16(16))
        d.append(contentsOf: Array("data".utf8))
        d.appendLE(UInt32(dataSize))
        d.append(Data(count: dataSize))
        return d
    }

    // MARK: 后台延长

    func beginExtendedRuntime(onWillExpire: @escaping () -> Void,
                              onInvalidated: @escaping (String) -> Void) {
        self.onWillExpire = onWillExpire
        self.onInvalidated = onInvalidated

        guard runtimeSession == nil else { return }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session
        AppLog.log("runtime.begin")
    }

    func endExtendedRuntime() {
        runtimeSession?.invalidate()
        runtimeSession = nil
        AppLog.log("runtime.end")
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

#if os(watchOS)
extension AudioSessionController: WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        AppLog.log("runtime.didStart expiration=\(extendedRuntimeSession.expirationDate?.description ?? "-")")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        AppLog.log("runtime.willExpire")
        onWillExpire?()
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        AppLog.log("runtime.invalidated reason=\(reason.rawValue) error=\(error?.localizedDescription ?? "-")")
        runtimeSession = nil
        onInvalidated?(Self.describe(reason))
    }

    private static func describe(_ reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none: return "本轮已结束"
        case .sessionInProgress: return "已有后台会话在运行"
        case .expired: return "后台运行时长已达系统上限"
        case .resignedFrontmost: return "应用退到后台，后台会话结束"
        case .suppressedBySystem: return "系统暂时不允许后台运行"
        default: return "后台会话异常结束"
        }
    }
}
#endif

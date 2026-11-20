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

    /// 连续激活失败达到阈值时回调。引擎会暂停并提示用户，
    /// **绝不静默把整个词库播完**——那是最难排查的一种失败。
    var onPersistentActivationFailure: (() -> Void)?

    var isRuntimeActive: Bool {
        runtimeSession?.state == .running
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: 音频会话

    func activate() {
        observeInterruption()
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
            let opts = session.categoryOptions.rawValue
            AppLog.log("audio.activate ok route=\(routeDescription) options=\(opts)")
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
                   + "count=\(activationFailures) retryIn=\(Int(delay))s")
        // 每满 3 次提醒一回：用户已经暂停过、又重新开始时，还有机会再被拦一次。
        if activationFailures >= 3, activationFailures % 3 == 0 {
            onPersistentActivationFailure?()
        }
    }

    func deactivate() {
        stopSilentKeepAlive()
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
                AppLog.log("audio.interruption began")
            case .ended:
                AppLog.log("audio.interruption ended")
                self.ensureActive()
            @unknown default:
                break
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
        guard keepAlive == nil else { return }
        do {
            let player = try AVAudioPlayer(data: Self.silentWave())
            player.numberOfLoops = -1
            player.volume = 1.0
            player.prepareToPlay()
            let ok = player.play()
            keepAlive = player
            AppLog.log("audio.keepalive start ok=\(ok)")
        } catch {
            AppLog.log("audio.keepalive failed: \(error.localizedDescription)")
        }
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

    /// 1 秒 8kHz 单声道 16bit 全零 WAV。内容是真的静音，不是把音量调 0，
    /// 这样会话才算"在渲染音频"，同时完全听不见。
    private static func silentWave(seconds: Double = 1.0, sampleRate: Int = 8000) -> Data {
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

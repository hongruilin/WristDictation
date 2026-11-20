import Foundation
import MediaPlayer
import AVFoundation

/// 耳机/锁屏按键的语义。
///
/// 这里刻意不判断"当前该播还是该停"——那是引擎的状态，桥只负责把
/// 系统投递过来的原始意图原样上报，避免两处各存一份状态而互相打脸。
enum TransportIntent: String {
    case play
    case pause
    case toggle
}

/// 媒体命令接入层。
///
/// watchOS 自 5.0 起提供 MPRemoteCommandCenter（已核对 watchOS 27.2 SDK 头文件
/// 的 MP_API 标注），因此 AirPods 的播放/暂停与上一首/下一首可以走系统链路，
/// 不需要 AVQueuePlayer 兜底。
final class RemoteCommandBridge {

    /// 播放/暂停类命令的统一出口。play / pause / toggle 三种意图都从这里进引擎，
    /// 由引擎按当前 phase 决定实际动作（见 DictationEngine.handleTransport）。
    var onTransport: ((TransportIntent) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var isActive = false

    /// 同一手势可能被系统解码成多个命令，去抖。
    ///
    /// play / pause / toggle 共用一个键 `transport`：AirPods 一次按压实测会同时
    /// 投递 toggle 与 pause（V1.3 现场日志），按命令名分别计数挡不住，会被当成两次操作。
    ///
    /// V1.5 把窗口从 0.35s 放宽到 0.5s。原因是暂停后恢复也走同一条 transport 键
    /// （见引擎里的状态驱动逻辑），如果系统把一次按压拆成 pause + play 两条、
    /// 间隔又落在 0.35~0.5 秒，就会出现"暂停后自己又播起来"的鬼畜现象。
    private var lastCommandAt: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 0.5
    private var lastPlayingState: Bool?
    /// 最近一次写进系统的 Now Playing 快照。系统清空后靠它重建，
    /// 否则暂停久了 Now Playing 一掉，耳机命令就再也转发不过来。
    private var lastInfo: [String: Any]?
    /// 上次真正写入的时间。用来把"周期性重写"降级成"仅在需要时重写"。
    private var lastWriteAt = Date.distantPast

    /// 命令回调可能来自任意线程（watchOS 在后台被耳机唤醒时尤其如此），
    /// 而 `lastCommandAt` 是普通字典，并发写会直接崩。用锁把它护住。
    private let stateLock = NSLock()

    func activate() {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.deliver(.play, key: "transport") ?? .commandFailed
        }

        center.pauseCommand.addTarget { [weak self] _ in
            self?.deliver(.pause, key: "transport") ?? .commandFailed
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.deliver(.toggle, key: "transport") ?? .commandFailed
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.shouldAccept("next") else { return .commandFailed }
            self.deliverOnMain { [weak self] in self?.onNext?() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.shouldAccept("previous") else { return .commandFailed }
            self.deliverOnMain { [weak self] in self?.onPrevious?() }
            return .success
        }

        AppLog.log("remote.activated")
    }

    func deactivate() {
        guard isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        isActive = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AppLog.log("remote.deactivated")
    }

    private func deliver(_ intent: TransportIntent, key: String) -> MPRemoteCommandHandlerStatus {
        guard shouldAccept(key, detail: intent.rawValue) else { return .commandFailed }
        deliverOnMain { [weak self] in self?.onTransport?(intent) }
        return .success
    }

    /// 主线程是硬要求。引擎里的 `@Published` 会驱动 SwiftUI 更新，
    /// 而 watchOS 在后台被耳机唤醒时，命令回调可能在后台队列上执行。
    /// 在非主线程改 SwiftUI 状态会把主线程卡住，随后被 watchdog 强杀——
    /// 这种终止**不产生 crash log**，表现就是"按一下耳机就闪退"。
    private func deliverOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func shouldAccept(_ key: String, detail: String? = nil, source: String = "remote") -> Bool {
        let now = Date()
        let suffix = detail.map { "/\($0)" } ?? ""

        stateLock.lock()
        let last = lastCommandAt[key]
        let accepted = (last == nil) || now.timeIntervalSince(last!) >= debounceInterval
        if accepted { lastCommandAt[key] = now }
        stateLock.unlock()

        if accepted {
            AppLog.log("\(source).command \(key)\(suffix)")
        } else {
            AppLog.log("\(source).debounced \(key)\(suffix)")
        }
        return accepted
    }

    /// 表盘上的双指互点（Double Tap）直接调这里，而不是绕过桥去改引擎状态。
    ///
    /// 两个理由：
    /// 1. **共享去抖**。App 是 Now Playing 应用，一次双击有可能既触发
    ///    `handGestureShortcut` 又被系统当成媒体命令投递一遍 `togglePlayPauseCommand`；
    ///    若两条路径各自生效，用户会看到"暂停后立刻又播起来"，像没反应。
    /// 2. **日志同源**。`gesture.command transport/toggle` 和 `remote.command ...`
    ///    摆在同一个文件里，出问题时一眼能区分是耳机来的还是手势来的。
    func gestureTransport(_ intent: TransportIntent) {
        guard shouldAccept("transport", detail: intent.rawValue, source: "gesture") else { return }
        deliverOnMain { [weak self] in self?.onTransport?(intent) }
    }

    /// 维护 Now Playing 信息。没有它，系统不会把这个 App 当作可控制的播放器，
    /// 耳机命令也就不会转发过来。
    ///
    /// watchOS 没有 `MPNowPlayingInfoCenter.playbackState`（那是 macOS/iOS 的属性），
    /// 系统靠音频会话判断播放状态，所以这里只需要把元信息填全：
    /// MediaType 缺了会显示成未知媒体，IsLiveStream 让系统按"直播"处理，
    /// 不去做曲目时长推算——TTS 的时长本来就估不准。
    func updateNowPlaying(title: String, isPlaying: Bool, elapsed: TimeInterval) {
        let center = MPNowPlayingInfoCenter.default()
        let titleChanged = (lastInfo?[MPMediaItemPropertyTitle] as? String) != title
        let stateChanged = lastPlayingState != isPlaying

        // 内容没变、系统那边也还留着这条信息，就不要再写一次。
        // 每次写入都是一趟 mediaremoted 的跨进程调用；一轮 50 词、每词重复两遍，
        // 会产生上百次内容完全相同的写入，纯属白烧电。
        if !titleChanged && !stateChanged && center.nowPlayingInfo != nil { return }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "腕上听写"
        info[MPMediaItemPropertyAlbumTitle] = "听写进行中"
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = 7200.0
        lastInfo = info
        lastWriteAt = Date()
        center.nowPlayingInfo = info

        if stateChanged {
            lastPlayingState = isPlaying
            AppLog.log("nowplaying playing=\(isPlaying) title=\(title)")
        }
    }

    /// 系统在某些时机会清掉 nowPlayingInfo（例如路由变化、被别的 App 抢过一次、
    /// 暂停时间较长），一掉就不再是 Now Playing，耳机命令随之彻底断开。
    /// 引擎在播报间隙和暂停心跳里周期性调用这里，成本是一次字典写入。
    /// 系统在某些时机会清掉 nowPlayingInfo（路由变化、被别的 App 抢过一次），
    /// 一旦清掉，耳机命令就再也转发不过来，所以引擎会周期性调用这里做兜底。
    ///
    /// 但**只在真的被清空时才写**：读 `nowPlayingInfo` 读的是本地属性，几乎零成本；
    /// 写它则要走 mediaremoted。原来每 5 秒无条件重写一次，一小时 720 次，
    /// 换来的还是同一个字典。30 秒的兜底只为应对"信息还在但已过期"的极端情况。
    func reassertNowPlaying() {
        guard isActive, let lastInfo else { return }
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo == nil {
            center.nowPlayingInfo = lastInfo
            lastWriteAt = Date()
            AppLog.log("nowplaying rebuilt (was cleared)")
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastWriteAt) >= 30 else { return }
        center.nowPlayingInfo = lastInfo
        lastWriteAt = now
    }
}

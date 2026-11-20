import Foundation
import MediaPlayer
import WatchConnectivity

/// iPhone 端的耳机命令桥（PRD 8.2 的 D5 兜底）：
/// 当 AirPods 连的是 iPhone 而不是手表时，命令在这里接收，再转发给手表执行。
///
/// 默认关闭。原因是两个设备同时注册媒体命令会导致同一个手势被处理两次，
/// 而且会在 iPhone 上留下一个"正在播放"的系统卡片。只有用户明确需要时才开。
final class PhoneRemoteBridge {

    static let shared = PhoneRemoteBridge()

    private let defaultsKey = "phoneRemoteEnabled"
    private var isActive = false
    private var lastCommandAt: [String: Date] = [:]

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            newValue ? activate() : deactivate()
        }
    }

    func refresh() {
        if isEnabled {
            activate()
        }
    }

    private func activate() {
        guard !isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.forward("play")
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.forward("pause")
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.forward("toggle")
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.forward("next")
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.forward("previous")
            return .success
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "腕上听写",
            MPMediaItemPropertyArtist: "手机遥控",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyPlaybackDuration: 7200.0
        ]

        isActive = true
        AppLog.log("phone.remote.activated")
    }

    private func deactivate() {
        guard isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        isActive = false
        AppLog.log("phone.remote.deactivated")
    }

    private func forward(_ command: String) {
        let now = Date()
        if let last = lastCommandAt[command], now.timeIntervalSince(last) < 0.25 {
            return
        }
        lastCommandAt[command] = now

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let payload: [String: Any] = [SyncProtocol.Key.command: command]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
        AppLog.log("phone.remote.forward \(command)")
    }
}

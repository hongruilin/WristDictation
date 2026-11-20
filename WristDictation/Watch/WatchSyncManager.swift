import Foundation
import WatchConnectivity
import Combine

/// Watch 端同步代理：接收完整词库、校验并交回 WatchStore 原子落盘，然后回执。
///
/// 设计要点（都是"同步为什么慢"的直接答案）：
///
/// 1. **能走快车道就走快车道**。iPhone 用 `sendMessage` 发过来时，这里在
///    `replyHandler` 里直接把回执塞回去——一次往返，不再额外发消息。
/// 2. **回执里带上手表状态和语音列表**。以前回执、状态、语音是三趟，
///    现在是同一趟，省掉两个排队跳。
/// 3. **幂等**。WC 会在会话重新激活时重放最后一包，重复包只回执、
///    不重复落盘、不重复推送——否则一次同步会放大成十几次。
final class WatchSyncManager: NSObject, ObservableObject {

    static let shared = WatchSyncManager()

    @Published private(set) var isActivated = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastAck: SyncAck?
    @Published private(set) var lastError: String?

    /// 校验通过后回调：(payload, dataVersion)。调用即代表"该落盘了"，
    /// 幂等判断已在本类里做完，回调方不必再查版本。
    var onPayload: ((SyncPayload, Int) -> Void)?
    /// iPhone 转发的播放命令（D5 兜底通道）
    var onCommand: ((String) -> Void)?
    /// 提供本机可用语音，供 iPhone 展示
    var voiceProvider: (() -> [SpeechVoice])?
    /// 提供本机实际生效的参数，供 iPhone 展示"手表已生效"
    var stateProvider: (() -> WatchStateReport)?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private var pendingPush: DispatchWorkItem?
    private var lastPushAt = Date.distantPast
    /// 上一次真正发出去的那包。可达性抖动会反复触发 pushState，
    /// 靠它把"内容完全一样"的重复推送挡掉。
    private var lastPushedContext: NSDictionary?
    private var lastDeliveredVersion = -1
    private var lastDeliverAt = Date.distantPast

    func activate() {
        guard let session else {
            AppLog.log("sync.activate unsupported")
            return
        }
        session.delegate = self
        session.activate()
    }

    // MARK: - 接收

    /// 处理一包数据。
    ///
    /// - Parameter reply: 非空时表示这是 `sendMessage` 的快车道，回执要原路返回，
    ///   不要再额外发消息（那会多出一个排队跳）。
    private func handleDictionaryData(_ data: Data, reply: (([String: Any]) -> Void)? = nil) {
        let started = Date()
        do {
            let verified = try SyncProtocol.decodeAndVerify(data)
            if !verified.hashValid {
                // 只留痕不拒收：历史上哈希不一致是"同步永远失败"的元凶。
                AppLog.log("sync.receive hash mismatch version=\(verified.envelope.dataVersion) accepted")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    reply?([:])
                    return
                }
                self.lastError = nil
                let response = self.applyAndBuildResponse(verified)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                AppLog.log("sync.done version=\(verified.envelope.dataVersion) bytes=\(data.count) apply=\(ms)ms lane=\(reply == nil ? "queued" : "fast")")

                if let reply {
                    reply(response)
                } else {
                    self.deliver(response, version: verified.envelope.dataVersion)
                }
            }
        } catch {
            let message = error.localizedDescription
            AppLog.log("sync.receive failed: \(message)")
            DispatchQueue.main.async { [weak self] in
                self?.lastError = message
            }
            reply?(["error": message])
        }
    }

    /// 落盘（幂等）+ 组装回包。回包同时带 ack、手表状态和语音列表。
    private func applyAndBuildResponse(_ verified: SyncProtocol.Verified) -> [String: Any] {
        let envelope = verified.envelope
        let currentVersion = stateProvider?().dataVersion ?? 0
        let applied = envelope.dataVersion > currentVersion

        if applied {
            onPayload?(envelope.payload, envelope.dataVersion)
        } else {
            AppLog.log("sync.duplicate version=\(envelope.dataVersion) current=\(currentVersion) → 只回执")
        }

        let ack = SyncAck(dataVersion: envelope.dataVersion,
                          libraryCount: envelope.payload.libraries.count,
                          entryCount: envelope.payload.libraries.reduce(0) { $0 + $1.entries.count },
                          receivedAt: Date(),
                          applied: applied)
        lastAck = ack

        var response: [String: Any] = [:]
        if let data = try? JSONCoding.encoder.encode(ack) {
            response[SyncProtocol.Key.ack] = data
        }
        if let report = stateProvider?(), let data = try? JSONCoding.encoder.encode(report) {
            response[SyncProtocol.Key.state] = data
        }
        if let voices = voiceProvider?(), let data = try? JSONCoding.encoder.encode(voices) {
            response[SyncProtocol.Key.voices] = data
        }
        return response
    }

    private func handleMessage(_ dict: [String: Any], reply: (([String: Any]) -> Void)? = nil) {
        if let envelope = dict[SyncProtocol.Key.envelope] {
            if let data = envelope as? Data {
                handleDictionaryData(data, reply: reply)
            } else if let nested = envelope as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: nested) {
                handleDictionaryData(data, reply: reply)
            } else {
                reply?(["error": "无法解析同步数据"])
            }
        } else {
            reply?(["ok": true])
        }
        if let command = dict[SyncProtocol.Key.command] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.onCommand?(command)
            }
        }
    }

    // MARK: - 发送

    /// 把回执发回 iPhone。可达时用 `sendMessage`（即时），否则用排队通道。
    ///
    /// 同一版本 3 秒内只回一次：手表 App 激活的瞬间，WC 会把最后一包重放
    /// 一到三次，每条都回执会让 iPhone 收到一串内容相同的回执和状态。
    private func deliver(_ dict: [String: Any], version: Int) {
        guard let session, !dict.isEmpty else { return }
        if version == lastDeliveredVersion,
           Date().timeIntervalSince(lastDeliverAt) < 3 {
            AppLog.log("sync.reply skipped version=\(version)（3 秒内已回过）")
            return
        }
        lastDeliveredVersion = version
        lastDeliverAt = Date()
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil) { [weak session] _ in
                session?.transferUserInfo(dict)
            }
        } else {
            session.transferUserInfo(dict)
        }
        AppLog.log("sync.reply sent keys=\(dict.keys.sorted().joined(separator: ","))")
    }

    /// 把手表的语音列表 + 当前生效参数回传给 iPhone。
    ///
    /// 合并发送是必须的：一次 `updateApplicationContext` 只保留最后一包。
    /// 节流也是必须的：可达性变化、启动、落盘都会触发，短时间内连推会
    /// 让 iPhone 收到一串过期状态，反而看不出哪次是最新的。
    func pushState() {
        let minInterval: TimeInterval = 1.0
        let elapsed = Date().timeIntervalSince(lastPushAt)
        guard elapsed >= minInterval else {
            pendingPush?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performPush() }
            pendingPush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - elapsed), execute: work)
            return
        }
        performPush()
    }

    private func performPush() {
        pendingPush = nil
        guard let session, session.activationState == .activated else { return }
        var context: [String: Any] = [:]
        if let voices = voiceProvider?(), let data = try? JSONCoding.encoder.encode(voices) {
            context[SyncProtocol.Key.voices] = data
        }
        if let report = stateProvider?(), let data = try? JSONCoding.encoder.encode(report) {
            context[SyncProtocol.Key.state] = data
        }
        guard !context.isEmpty else { return }

        // 内容没变就别发。
        //
        // 可达性抖动会高频触发 pushState（V1.6.1 实测：4 分 20 秒里 14 次，
        // version 一直是 75，状态根本没变）。每发一次都要编码整份语音列表、
        // 再走一趟蓝牙，纯属白烧电，手机那边收到的还是一模一样的包。
        //
        // 用 NSDictionary 做深比较：Data 值按内容比，代价远低于一次传输。
        let snapshot = context as NSDictionary
        if let last = lastPushedContext, last.isEqual(snapshot) {
            AppLog.log("sync.pushState skipped (identical) version=\(stateProvider?().dataVersion ?? -1)")
            return
        }
        lastPushedContext = snapshot

        lastPushAt = Date()
        try? session.updateApplicationContext(context)
        AppLog.log("sync.pushState keys=\(context.keys.sorted().joined(separator: ",")) version=\(stateProvider?().dataVersion ?? -1)")
    }

    /// 只刷新状态，不重复枚举语音（语音 60 秒缓存，代价可忽略）。
    func sendVoices() { pushState() }
}

// MARK: - WCSessionDelegate

extension WatchSyncManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
            if let error {
                self.lastError = error.localizedDescription
            }
        }
        AppLog.log("sync.activation=\(activationState.rawValue)")
        if activationState == .activated {
            pushState()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
            if session.isReachable {
                self?.pushState()
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleMessage(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleMessage(userInfo)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL) else {
            AppLog.log("sync.file unreadable")
            return
        }
        handleDictionaryData(data)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }

    /// 快车道入口：回执在同一次往返里返回，手机侧不需要等第二趟。
    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        handleMessage(message, reply: replyHandler)
    }
}

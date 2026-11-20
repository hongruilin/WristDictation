import Foundation
import CryptoKit

// MARK: - 编解码约定

/// 两端必须使用同一套 JSON 约定，否则 Date 会一边是 Double 一边是字符串。
enum JSONCoding {
    /// 编码器必须排序键。
    ///
    /// 为什么：Foundation 的 `JSONEncoder` 不保证多次编码的键顺序一致
    /// （同一个值连编两次都可能不同）。同步信封的内容哈希是"发出前算一次、
    /// 收到后重算一次"，键顺序一变就必然校验失败——手表会以
    /// 「哈希不一致」拒收每一条同步，手机上表现为永远"同步失败"。
    /// 排序键后两端字节一致，哈希才有意义。
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 兼容历史数据：先按 ISO8601 解，失败再按时间戳解。
    static func lenientDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self), let date = ISO8601DateFormatter().date(from: s) {
                return date
            }
            if let t = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: t)
            }
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "无法解析日期")
        }
        return d
    }
}

// MARK: - 同步数据结构

struct SyncPayload: Codable {
    var libraries: [WordLibrary]
    var settings: AppSettings
}

struct SyncEnvelope: Codable {
    var schemaVersion: Int
    var dataVersion: Int
    var contentHash: String
    var createdAt: Date
    var payload: SyncPayload
}

struct SyncAck: Codable {
    var dataVersion: Int
    var libraryCount: Int
    var entryCount: Int
    var receivedAt: Date
    /// 这一包是否真的落盘了。`false` 表示手表本地已经是这个版本（重复投递）。
    /// 用 optional 是为了兼容旧版本手表发来的回执。
    var applied: Bool?
}

/// 手表侧把"我这边实际生效的参数"回传给手机。
///
/// 为什么需要：侧载安装时 `WCSession.isWatchAppInstalled` / `isReachable`
/// 长期为 false，手机端无法判断同步到底有没有落地。靠手表主动上报，
/// 手机才有可信的"手表当前生效值"，而不是只看自己发出去的状态。
struct WatchStateReport: Codable {
    var dataVersion: Int
    var libraryCount: Int
    var entryCount: Int
    var repeatCount: Int
    var sameWordGap: Double
    var nextWordGap: Double
    var isManualAdvance: Bool
    var voiceName: String?
    var speechRate: Double
    /// 省电模式是否在手表上生效。optional 是为了兼容旧版本手表发来的报告。
    var powerSaving: Bool?
    var reportedAt: Date

    static let empty = WatchStateReport(dataVersion: 0,
                                        libraryCount: 0,
                                        entryCount: 0,
                                        repeatCount: 2,
                                        sameWordGap: 3,
                                        nextWordGap: 5,
                                        isManualAdvance: false,
                                        voiceName: nil,
                                        speechRate: 0.45,
                                        powerSaving: nil,
                                        reportedAt: .distantPast)

    var summary: String {
        let base = "v\(dataVersion) · \(repeatCount) 次 · \(ParameterLimits.formatGap(sameWordGap))/\(ParameterLimits.formatGap(nextWordGap)) 秒\(isManualAdvance ? " · 手动" : "")"
        return powerSaving == true ? base + " · 省电" : base
    }

    /// 除 `reportedAt` 之外是否完全一致。
    /// 手表侧用它决定"内容没变就别刷新时间戳"，从而让同步层能把重复包挡掉。
    func sameContent(as other: WatchStateReport) -> Bool {
        dataVersion == other.dataVersion
            && libraryCount == other.libraryCount
            && entryCount == other.entryCount
            && repeatCount == other.repeatCount
            && sameWordGap == other.sameWordGap
            && nextWordGap == other.nextWordGap
            && isManualAdvance == other.isManualAdvance
            && voiceName == other.voiceName
            && speechRate == other.speechRate
            && powerSaving == other.powerSaving
    }
}

enum SyncError: LocalizedError {
    case emptyPayload
    case hashMismatch
    case schemaTooNew(Int)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyPayload: return "同步内容为空"
        case .hashMismatch: return "数据校验失败（哈希不一致）"
        case .schemaTooNew(let v): return "数据版本 \(v) 高于当前 App 支持的版本"
        case .encodingFailed: return "数据序列化失败"
        }
    }
}

// MARK: - 协议常量

enum SyncProtocol {
    static let schemaVersion = 1

    /// applicationContext 的实际上限约 256KB，留出余量后按 200KB 分流。
    static let contextSizeLimit = 200 * 1024

    /// 快车道上限。
    ///
    /// `sendMessage` 是唯一"即时"的通道（两端 App 都在前台时约 100–300ms 一个往返），
    /// 但它是直传内存、没有队列保障，包太大时容易失败。实测一包 100 条词条约 11KB，
    /// 1000 条约 107KB，所以按 32KB 切（约 300 条以内都走快车道）。
    /// 超出的部分退回 applicationContext —— 它慢，但保证送达。
    static let fastLaneLimit = 32 * 1024

    enum Channel {
        case applicationContext
        case file
    }

    /// 同步消息里携带的键。写错一个就会静默失败，集中定义。
    enum Key {
        static let envelope = "envelope"
        static let ack = "ack"
        static let voices = "voices"
        static let command = "command"
        static let state = "state"
    }

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 生成可直接发送的信封。哈希基于 payload 的规范化 JSON，不含元数据。
    static func makeEnvelope(libraries: [WordLibrary],
                             settings: AppSettings,
                             dataVersion: Int) throws -> (envelope: SyncEnvelope, data: Data, channel: Channel) {
        let payload = SyncPayload(libraries: libraries, settings: settings)
        let encoder = JSONCoding.encoder

        guard let payloadData = try? encoder.encode(payload) else {
            throw SyncError.encodingFailed
        }
        let hash = sha256(payloadData)

        let envelope = SyncEnvelope(schemaVersion: schemaVersion,
                                    dataVersion: dataVersion,
                                    contentHash: hash,
                                    createdAt: Date(),
                                    payload: payload)
        guard let envelopeData = try? encoder.encode(envelope) else {
            throw SyncError.encodingFailed
        }
        let channel: Channel = envelopeData.count <= contextSizeLimit ? .applicationContext : .file
        return (envelope, envelopeData, channel)
    }

    struct Verified {
        var envelope: SyncEnvelope
        /// 内容哈希是否对上。false 只记日志、不拒收（理由见下）。
        var hashValid: Bool
    }

    /// 解码并校验。
    ///
    /// 结构性问题（无法解码 / schema 过新 / 空词库）仍然抛错；
    /// 内容哈希不一致只作为告警返回，**不再拒收整包**。
    ///
    /// 为什么不拒收：哈希要求两端把同一份 payload 序列化成完全相同的字节，
    /// 这依赖 Foundation 编码器的实现细节。一旦漂移，代价是整次同步丢失
    /// （用户侧表现就是"同步失败"且毫无线索）。传输本身有完整性保证，
    /// 解码成功又已经证明结构合法，为哈希漂移丢数据不划算。
    static func decodeAndVerify(_ data: Data) throws -> Verified {
        let decoder = JSONCoding.lenientDecoder()
        guard let envelope = try? decoder.decode(SyncEnvelope.self, from: data) else {
            throw SyncError.encodingFailed
        }
        guard envelope.schemaVersion <= schemaVersion else {
            throw SyncError.schemaTooNew(envelope.schemaVersion)
        }
        guard !envelope.payload.libraries.isEmpty else {
            throw SyncError.emptyPayload
        }
        let recomputed = (try? JSONCoding.encoder.encode(envelope.payload)).map(sha256)
        return Verified(envelope: envelope, hashValid: recomputed == envelope.contentHash)
    }
}

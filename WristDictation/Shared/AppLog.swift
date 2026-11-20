import Foundation

/// 统一的轻量日志。听写长稳验收（B04）需要时间轴可追溯，
/// 因此关键状态迁移都通过这里落盘，界面不参与。
///
/// 耗电相关的两处设计（2026-11-19）：
/// 1. 句柄长住。原来每写一行都要 open → seek → write → close，
///    一轮 50 词累积上百次文件打开/关闭，在闪存上是实打实的元数据写入。
/// 2. 超过 512KB 自动换成上一份。`tail()` 会把整个文件读进内存，
///    而手表后台的内存上限很紧，日志不能让它无限长。
enum AppLog {
    private static let queue = DispatchQueue(label: "applog.queue")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var handle: FileHandle?
    private static var written = 0
    private static let rotationBytes = 512 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("WristDictation", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var fileURL: URL {
        directory.appendingPathComponent("run.log")
    }

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            if handle == nil { openLocked() }
            guard handle != nil else {
                // 句柄拿不到（极少数容器异常）时退回一次性写入，至少别丢日志。
                try? data.write(to: fileURL)
                return
            }
            if written + data.count > rotationBytes {
                rotateLocked()
            }
            guard let fileHandle = handle else { return }
            do {
                try fileHandle.write(contentsOf: data)
                written += data.count
            } catch {
                handle = nil
            }
        }
    }

    /// 读取日志尾部，供界面排查使用。
    static func tail(maxLines: Int = 400) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func reset() {
        queue.sync {
            try? handle?.close()
            handle = nil
            written = 0
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: 私有（只在 queue 上调用）

    private static func openLocked() {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        _ = try? opened.seekToEnd()
        handle = opened
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        written = (attrs?[.size] as? Int) ?? 0
    }

    private static func rotateLocked() {
        try? handle?.close()
        handle = nil
        let url = fileURL
        let old = url.deletingLastPathComponent().appendingPathComponent("run.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        written = 0
        openLocked()
    }
}

import Foundation
import CoreFoundation

// MARK: - 导入格式

enum ImportFormat: String {
    case txt
    case csv
    case json

    static func detect(fileName: String) -> ImportFormat? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "txt", "text": return .txt
        case "csv": return .csv
        case "json": return .json
        default: return nil
        }
    }
}

struct ImportIssue: Identifiable, Hashable {
    var id = UUID()
    var line: Int
    var message: String
}

struct ImportOutcome {
    var entries: [VocabularyEntry] = []
    /// 与目标词库（或文件内前面已出现的词条）重复的条数。
    var duplicateCount: Int = 0
    var failures: [ImportIssue] = []
    var totalParsed: Int = 0
    var libraryName: String?
    var libraryDefaults: ParameterLayer?
    var libraryMode: PlaybackMode?

    var successCount: Int { entries.count }
}

// MARK: - 导入导出

enum DictionaryIO {

    static let schemaVersion = 1

    // MARK: 编码

    /// 编码探测：BOM → UTF-8 严格 → GB18030。
    /// 中文 CSV 常常是 Excel 导出的 GBK，必须支持，否则导入一片乱码。
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return s
        }
        // 最后尝试 UTF-16，覆盖部分 Windows 记事本导出
        return String(data: data, encoding: .utf16)
    }

    // MARK: 统一入口

    static func importData(_ data: Data,
                           fileName: String,
                           defaultLayer: ParameterLayer,
                           existingTexts: Set<String>) -> ImportOutcome {
        guard let format = ImportFormat.detect(fileName: fileName) else {
            var outcome = ImportOutcome()
            outcome.failures.append(ImportIssue(line: 0, message: "不支持的文件类型，仅支持 TXT、CSV、JSON"))
            return outcome
        }
        guard let text = decodeText(data) else {
            var outcome = ImportOutcome()
            outcome.failures.append(ImportIssue(line: 0, message: "无法识别文件编码，请另存为 UTF-8 后重试"))
            return outcome
        }
        return importText(text, format: format, defaultLayer: defaultLayer, existingTexts: existingTexts)
    }

    static func importText(_ text: String,
                           format: ImportFormat,
                           defaultLayer: ParameterLayer,
                           existingTexts: Set<String>) -> ImportOutcome {
        switch format {
        case .txt: return parseTXT(text, existingTexts: existingTexts)
        case .csv: return parseCSV(text, existingTexts: existingTexts)
        case .json: return parseJSON(text)
        }
    }

    // MARK: TXT

    static func parseTXT(_ text: String, existingTexts: Set<String>) -> ImportOutcome {
        var outcome = ImportOutcome()
        var seen = existingTexts
        let lines = text.components(separatedBy: .newlines)
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            outcome.totalParsed += 1
            let entry = VocabularyEntry(text: line)
            if seen.contains(entry.normalizedText) {
                outcome.duplicateCount += 1
                continue
            }
            seen.insert(entry.normalizedText)
            outcome.entries.append(entry)
        }
        return outcome
    }

    // MARK: CSV

    static func parseCSV(_ text: String, existingTexts: Set<String>) -> ImportOutcome {
        var outcome = ImportOutcome()
        let separator = detectSeparator(text)
        let rows = parseCSVRows(text, separator: separator)
        guard !rows.isEmpty else {
            outcome.failures.append(ImportIssue(line: 1, message: "文件为空"))
            return outcome
        }

        // 表头识别：含"词条"或"text"即认为是表头
        let first = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let hasHeader = first.contains { $0.contains("词条") || $0 == "text" || $0 == "word" || $0 == "内容" }
        let header = hasHeader ? rows[0].map { $0.trimmingCharacters(in: .whitespaces) } : []
        let startRow = hasHeader ? 1 : 0

        let textIndex = headerIndex(header, candidates: ["词条", "文本", "内容", "text", "word"], fallback: 0)
        let repeatIndex = headerIndex(header, candidates: ["播报次数", "次数", "repeat", "repeatcount"], fallback: nil)
        let sameIndex = headerIndex(header, candidates: ["同词重复间隔秒", "同词重复间隔", "同词间隔", "samewordgap", "samegap"], fallback: nil)
        let nextIndex = headerIndex(header, candidates: ["下一词间隔秒", "下一词间隔", "下一词gap", "nextwordgap", "nextgap"], fallback: nil)
        let textColumn = textIndex ?? 0

        var seen = existingTexts

        for rowNumber in startRow..<rows.count {
            let row = rows[rowNumber]
            let displayLine = rowNumber + 1
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            outcome.totalParsed += 1

            guard textColumn < row.count else {
                outcome.failures.append(ImportIssue(line: displayLine, message: "缺少词条列"))
                continue
            }
            let rawText = row[textColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            if rawText.isEmpty {
                outcome.failures.append(ImportIssue(line: displayLine, message: "词条为空"))
                continue
            }

            var layer = ParameterLayer()

            if let ri = repeatIndex, ri < row.count {
                let cell = row[ri].trimmingCharacters(in: .whitespaces)
                if !cell.isEmpty {
                    guard let value = Int(cell) else {
                        outcome.failures.append(ImportIssue(line: displayLine, message: "播报次数不是整数：\(cell)"))
                        continue
                    }
                    guard ParameterLimits.repeatCountRange.contains(value) else {
                        outcome.failures.append(ImportIssue(line: displayLine, message: "播报次数超出 1–20：\(value)"))
                        continue
                    }
                    layer.repeatCount = value
                }
            }

            if let si = sameIndex, si < row.count {
                let cell = row[si].trimmingCharacters(in: .whitespaces)
                if !cell.isEmpty {
                    guard let value = Double(cell), ParameterLimits.gapRange.contains(value) else {
                        outcome.failures.append(ImportIssue(line: displayLine, message: "同词重复间隔非法：\(cell)"))
                        continue
                    }
                    layer.sameWordGap = value
                }
            }

            if let ni = nextIndex, ni < row.count {
                let cell = row[ni].trimmingCharacters(in: .whitespaces)
                if !cell.isEmpty {
                    if cell == "手动" || cell.lowercased() == "manual" {
                        layer.isManualAdvance = true
                    } else {
                        guard let value = Double(cell), ParameterLimits.gapRange.contains(value) else {
                            outcome.failures.append(ImportIssue(line: displayLine, message: "下一词间隔非法：\(cell)"))
                            continue
                        }
                        layer.nextWordGap = value
                    }
                }
            }

            let entry = VocabularyEntry(text: rawText, overrides: layer)
            if seen.contains(entry.normalizedText) {
                outcome.duplicateCount += 1
                continue
            }
            seen.insert(entry.normalizedText)
            outcome.entries.append(entry)
        }
        return outcome
    }

    private static func detectSeparator(_ text: String) -> Character {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let candidates: [Character] = [",", ";", "\t"]
        var best: Character = ","
        var bestCount = -1
        for c in candidates {
            let count = firstLine.filter { $0 == c }.count
            if count > bestCount {
                bestCount = count
                best = c
            }
        }
        return best
    }

    private static func headerIndex(_ header: [String], candidates: [String], fallback: Int?) -> Int? {
        guard !header.isEmpty else { return fallback }
        for (i, cell) in header.enumerated() {
            let lower = cell.lowercased()
            for c in candidates where lower.contains(c.lowercased()) {
                return i
            }
        }
        return fallback
    }

    /// 简单 CSV 状态机：支持双引号包裹与引号内转义。
    private static func parseCSVRows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text)
        var i = 0

        while i < iterator.count {
            let ch = iterator[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < iterator.count && iterator[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == separator {
                    currentRow.append(field)
                    field = ""
                } else if ch == "\n" {
                    currentRow.append(field)
                    rows.append(currentRow)
                    currentRow = []
                    field = ""
                } else if ch == "\r" {
                    // 忽略，等待 \n
                } else {
                    field.append(ch)
                }
            }
            i += 1
        }
        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            rows.append(currentRow)
        }
        return rows
    }

    // MARK: JSON

    struct Archive: Codable {
        var schemaVersion: Int
        var exportedAt: Date
        var libraries: [WordLibrary]
        var settings: AppSettings?
    }

    static func parseJSON(_ text: String) -> ImportOutcome {
        var outcome = ImportOutcome()
        guard let data = text.data(using: .utf8) else {
            outcome.failures.append(ImportIssue(line: 0, message: "文本无法转换为 UTF-8"))
            return outcome
        }
        let decoder = JSONCoding.lenientDecoder()

        // 优先按归档格式读取
        if let archive = try? decoder.decode(Archive.self, from: data) {
            guard archive.schemaVersion <= schemaVersion else {
                outcome.failures.append(ImportIssue(line: 0, message: "文件版本（\(archive.schemaVersion)）高于当前 App，请先升级"))
                return outcome
            }
            var seen = Set<String>()
            for lib in archive.libraries {
                for entry in lib.entries {
                    outcome.totalParsed += 1
                    if seen.contains(entry.normalizedText) {
                        outcome.duplicateCount += 1
                    } else {
                        seen.insert(entry.normalizedText)
                    }
                }
            }
            outcome.entries = archive.libraries.flatMap { $0.entries }
            if let first = archive.libraries.first {
                outcome.libraryName = first.name
                outcome.libraryDefaults = first.defaults
                outcome.libraryMode = first.mode
            }
            return outcome
        }

        // 兼容单个词库
        if let lib = try? decoder.decode(WordLibrary.self, from: data) {
            outcome.entries = lib.entries
            outcome.totalParsed = lib.entries.count
            outcome.libraryName = lib.name
            outcome.libraryDefaults = lib.defaults
            outcome.libraryMode = lib.mode
            return outcome
        }

        // 兼容纯词条数组
        if let entries = try? decoder.decode([VocabularyEntry].self, from: data) {
            outcome.entries = entries
            outcome.totalParsed = entries.count
            return outcome
        }

        outcome.failures.append(ImportIssue(line: 0, message: "JSON 结构无法识别（需要词库归档或词库对象）"))
        return outcome
    }

    static func exportArchive(libraries: [WordLibrary], settings: AppSettings) -> Data? {
        let archive = Archive(schemaVersion: schemaVersion,
                              exportedAt: Date(),
                              libraries: libraries,
                              settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(archive)    }

    // MARK: 示例模板

    static let csvTemplate = """
    词条,播报次数,同词重复间隔秒,下一词间隔秒
    鞭辟入里,2,3,5
    相形见绌,3,4,8
    饮鸩止渴,1,0,5
    罄竹难书,2,6,10
    """

    static let txtTemplate = """
    鞭辟入里
    相形见绌
    饮鸩止渴
    罄竹难书
    学而不思则罔
    """
}

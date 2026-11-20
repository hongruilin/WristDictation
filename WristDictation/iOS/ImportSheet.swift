import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    let libraryID: UUID

    @EnvironmentObject var store: IOSStore
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var outcome: ImportOutcome?
    @State private var fileName = ""
    @State private var replaceExisting = false
    @State private var showFailures = false
    @State private var templateMessage: String?

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .json]
        if let csv = UTType(filenameExtension: "csv") {
            types.append(csv)
        }
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label(fileName.isEmpty ? "选择文件" : "重新选择（\(fileName)）",
                              systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("支持 TXT（每行一条）、CSV（可带独立参数）、JSON（完整词库）。中文文件可以是 UTF-8 或 GBK 编码。")
                }

                if let outcome {
                    resultSection(outcome)
                } else {
                    Section("格式说明") {
                        formatHelp
                    }
                    Section {
                        Button("把 CSV 模板存到「文件」App") {
                            writeTemplate(.csv)
                        }
                        Button("把 TXT 模板存到「文件」App") {
                            writeTemplate(.txt)
                        }
                    } footer: {
                        if let templateMessage {
                            Text(templateMessage)
                        } else {
                            Text("用「文件」App 打开模板，照着填好后再导入。")
                        }
                    }
                }
            }
            .navigationTitle("导入词条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let outcome, outcome.successCount > 0 {
                        Button("导入 \(outcome.successCount) 条") {
                            store.addEntries(libraryID: libraryID,
                                             entries: outcome.entries,
                                             replace: replaceExisting)
                            dismiss()
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: allowedTypes,
                          allowsMultipleSelection: false) { result in
                handlePicker(result)
            }
        }
    }

    // MARK: 结果

    @ViewBuilder
    private func resultSection(_ outcome: ImportOutcome) -> some View {
        Section("解析结果") {
            LabeledContent("成功", value: "\(outcome.successCount) 条")
            if outcome.duplicateCount > 0 {
                LabeledContent("已存在（跳过）", value: "\(outcome.duplicateCount) 条")
            }
            if !outcome.failures.isEmpty {
                Button {
                    showFailures.toggle()
                } label: {
                    LabeledContent("失败", value: "\(outcome.failures.count) 条")
                        .foregroundStyle(.red)
                }
                if showFailures {
                    ForEach(outcome.failures) { issue in
                        Text("第 \(issue.line) 行：\(issue.message)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            Toggle("替换现有词条（否则追加）", isOn: $replaceExisting)
        }

        if !outcome.entries.isEmpty {
            Section("预览（前 20 条）") {
                ForEach(Array(outcome.entries.prefix(20).enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.text)
                        Spacer()
                        Text(paramSummary(entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func paramSummary(_ entry: VocabularyEntry) -> String {
        var parts: [String] = []
        if let r = entry.overrides.repeatCount { parts.append("×\(r)") }
        if let g = entry.overrides.sameWordGap { parts.append("同词\(ParameterLimits.formatGap(g))s") }
        if entry.overrides.isManualAdvance == true { parts.append("手动") }
        else if let g = entry.overrides.nextWordGap { parts.append("下词\(ParameterLimits.formatGap(g))s") }
        return parts.isEmpty ? "继承" : parts.joined(separator: " ")
    }

    private var formatHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TXT：每个非空行一条词目").font(.caption).bold()
            Text("鞭辟入里\n相形见绌\n饮鸩止渴")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider()

            Text("CSV：可带独立参数，缺省继承词库默认").font(.caption).bold()
            Text("词条,播报次数,同词重复间隔秒,下一词间隔秒\n鞭辟入里,2,3,5\n相形见绌,3,4,8")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("下一词间隔填「手动」表示该词播完等待手动切换。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    // MARK: 动作

    private func handlePicker(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                outcome = ImportOutcome(failures: [ImportIssue(line: 0, message: "文件读取失败")])
                return
            }

            let library = store.library(id: libraryID)
            let defaultLayer = library?.defaults ?? ParameterLayer()
            let existing = Set((library?.entries ?? []).map { $0.normalizedText })

            fileName = url.lastPathComponent
            outcome = DictionaryIO.importData(data,
                                              fileName: url.lastPathComponent,
                                              defaultLayer: defaultLayer,
                                              existingTexts: existing)
        case .failure(let error):
            outcome = ImportOutcome(failures: [ImportIssue(line: 0, message: error.localizedDescription)])
        }
    }

    private func writeTemplate(_ format: ImportFormat) {
        let content = format == .csv ? DictionaryIO.csvTemplate : DictionaryIO.txtTemplate
        let name = format == .csv ? "腕上听写-模板.csv" : "腕上听写-模板.txt"
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent(name)
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            templateMessage = "已保存到「文件 > 我的 iPhone > 腕上听写」"
        } catch {
            templateMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 批量粘贴

/// 从剪贴板/备忘录整段粘贴词条：一行一条。
///
/// 为什么不复用 `ImportSheet`：导入是"选文件 → 解析 → 确认"，
/// 粘贴是"直接贴 → 当场看条数 → 确认"，中间不该出现文件选择器。
/// 解析仍走 `DictionaryIO.parseTXT`，与 TXT 导入完全同一套规则，
/// 不另写一份解析逻辑。
struct BatchPasteSheet: View {
    let libraryID: UUID

    @EnvironmentObject var store: IOSStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var replaceExisting = false
    @State private var outcome = ImportOutcome()

    private var canSubmit: Bool { outcome.successCount > 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("鞭辟入里\n相形见绌\n饮鸩止渴\n三人行必有我师")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .allowsHitTesting(false)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                            }
                        }
                } header: {
                    Text("每行一条")
                } footer: {
                    Text("空行自动忽略；与本词库已有条目重复的会跳过。参数沿用词库默认设置，加进来之后可以再逐条单独调整。")
                }

                Section {
                    LabeledContent("可添加", value: "\(outcome.successCount) 条")
                    if outcome.duplicateCount > 0 {
                        LabeledContent("重复跳过", value: "\(outcome.duplicateCount) 条")
                    }
                    Toggle("替换现有词条", isOn: $replaceExisting)
                } header: {
                    Text("预览")
                } footer: {
                    if replaceExisting {
                        Text("开启后，词库现有条目会先被清空。解析时不再与旧条目比对重复。")
                    }
                }
            }
            .navigationTitle("批量粘贴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 \(outcome.successCount) 条") {
                        store.addEntries(libraryID: libraryID,
                                         entries: outcome.entries,
                                         replace: replaceExisting)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
            .onChange(of: text) { _, _ in reparse() }
            .onChange(of: replaceExisting) { _, _ in reparse() }
        }
    }

    private func reparse() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outcome = ImportOutcome()
            return
        }
        // 替换模式下，旧条目马上会被清掉，不该再拿它们判重。
        let library = store.library(id: libraryID)
        let existing = replaceExisting ? [] : Set((library?.entries ?? []).map { $0.normalizedText })
        outcome = DictionaryIO.parseTXT(trimmed, existingTexts: existing)
    }
}

import SwiftUI

struct LibrarySettingsView: View {
    let libraryID: UUID

    @EnvironmentObject var store: IOSStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: PlaybackMode = .sequential
    @State private var overrideRepeat = false
    @State private var repeatCount = 2
    @State private var overrideSame = false
    @State private var sameGapText = ""
    @State private var overrideNext = false
    @State private var nextGapText = ""
    @State private var overrideManual = false
    @State private var manualAdvance = false

    @State private var estimate: TimeInterval = 0
    @State private var showGlobalSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("播放模式", selection: $mode) {
                        ForEach(PlaybackMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(mode.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("模式")
                }

                Section {
                    paramRow(title: "播报次数",
                             isOn: $overrideRepeat,
                             inherited: globalSummary.repeat,
                             editor: {
                                 Stepper("\(repeatCount) 次",
                                         value: $repeatCount,
                                         in: ParameterLimits.repeatCountRange)
                             })

                    paramRow(title: "同词重复间隔",
                             isOn: $overrideSame,
                             inherited: globalSummary.same,
                             editor: {
                                 HStack {
                                     TextField("秒", text: $sameGapText)
                                         .keyboardType(.decimalPad)
                                     Text("秒").foregroundStyle(.secondary)
                                 }
                             })

                    paramRow(title: "下一词间隔",
                             isOn: $overrideNext,
                             inherited: globalSummary.next,
                             editor: {
                                 HStack {
                                     TextField("秒", text: $nextGapText)
                                         .keyboardType(.decimalPad)
                                     Text("秒").foregroundStyle(.secondary)
                                 }
                             })
                            .disabled(manualAdvance)

                    paramRow(title: "手动推进",
                             isOn: $overrideManual,
                             inherited: globalSummary.manual,
                             editor: {
                                 Toggle("播完后等待手动切换", isOn: $manualAdvance)
                             })
                } header: {
                    Text("词库默认参数")
                } footer: {
                    Text("未开启的项沿用全局默认。单条词条还可以再单独覆盖一次。")
                }

                Section("本轮预计") {
                    if let library = store.library(id: libraryID) {
                        Text("\(library.enabledCount) 条 · 约 \(ParameterResolver.formatDuration(estimate))")
                            .font(.subheadline)
                        if estimate > 45 * 60 {
                            Label("本轮较长，建议分段练习，避免触发系统后台时长上限。",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("语音") {
                    if store.watchVoices.isEmpty {
                        Text("连接手表后，这里会显示手表实际可用的中文语音。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.watchVoices) { voice in
                            HStack {
                                Text(voice.name)
                                Spacer()
                                Text(voice.qualityLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("语音与语速（全局设置）") {
                        showGlobalSettings = true
                    }
                }
            }
            .navigationTitle("播报设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear(perform: load)
            .onChange(of: mode) { _, _ in updateEstimate() }
            .onChange(of: repeatCount) { _, _ in updateEstimate() }
            .sheet(isPresented: $showGlobalSettings) {
                GlobalSettingsView()
                    .environmentObject(store)
            }
        }
    }

    // MARK: 子视图

    @ViewBuilder
    private func paramRow<Editor: View>(title: String,
                                        isOn: Binding<Bool>,
                                        inherited: String,
                                        @ViewBuilder editor: () -> Editor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn)
            if isOn.wrappedValue {
                editor()
            } else {
                Text("沿用全局：\(inherited)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 全局摘要

    private var globalSummary: (repeat: String, same: String, next: String, manual: String) {
        let g = store.settings.global.merged(over: ParameterResolver.absoluteDefault)
        return (
            "\(g.repeatCount ?? 2) 次",
            "\(ParameterLimits.formatGap(g.sameWordGap ?? 3)) 秒",
            "\(ParameterLimits.formatGap(g.nextWordGap ?? 5)) 秒",
            (g.isManualAdvance ?? false) ? "手动" : "自动"
        )
    }

    // MARK: 读写

    private func load() {
        guard let library = store.library(id: libraryID) else { return }
        mode = library.mode

        let d = library.defaults
        if let value = d.repeatCount {
            overrideRepeat = true
            repeatCount = value
        }
        if let value = d.sameWordGap {
            overrideSame = true
            sameGapText = ParameterLimits.formatGap(value)
        }
        if let value = d.nextWordGap {
            overrideNext = true
            nextGapText = ParameterLimits.formatGap(value)
        }
        if let value = d.isManualAdvance {
            overrideManual = true
            manualAdvance = value
        }
        updateEstimate()
    }

    private func save() {
        var layer = ParameterLayer()
        if overrideRepeat { layer.repeatCount = ParameterLimits.clampRepeat(repeatCount) }
        if overrideSame, let v = Double(sameGapText.trimmingCharacters(in: .whitespaces)) {
            layer.sameWordGap = ParameterLimits.clampGap(v)
        }
        if overrideNext, !manualAdvance, let v = Double(nextGapText.trimmingCharacters(in: .whitespaces)) {
            layer.nextWordGap = ParameterLimits.clampGap(v)
        }
        if overrideManual { layer.isManualAdvance = manualAdvance }

        store.updateLibrary(id: libraryID) { lib in
            lib.mode = mode
            lib.defaults = layer
        }
        // 改完立刻推给手表，不要求用户再回到同步页手动点一次。
        store.syncToWatch(force: true)
        dismiss()
    }

    private func updateEstimate() {
        guard var library = store.library(id: libraryID) else { return }
        library.mode = mode
        if overrideRepeat {
            library.defaults.repeatCount = ParameterLimits.clampRepeat(repeatCount)
        }
        estimate = ParameterResolver.estimateDuration(library: library, settings: store.settings)
    }
}

// MARK: - 全局播报设置（手机端主入口）

/// 手机侧的统一配置面板：节奏 + 声音 + 同步状态。
///
/// 定位：这是"应该在哪里改参数"的答案。手表端保留同一套设置只为应急
/// （比如手机不在手边），但手机保存后会立刻整体覆盖手表，以手机为准。
struct GlobalSettingsView: View {
    @EnvironmentObject var store: IOSStore
    @Environment(\.dismiss) private var dismiss

    @State private var repeatCount = 2
    @State private var sameGap: Double = 3
    @State private var nextGap: Double = 5
    @State private var manual = false
    @State private var voice = ""
    @State private var rate: Double = 0.45
    @State private var powerSaving = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("播报次数：\(repeatCount) 次", value: $repeatCount, in: 1...5)

                    Picker("同词间隔", selection: $sameGap) {
                        ForEach(ParameterPresets.gapOptions(including: sameGap), id: \.self) { value in
                            Text(ParameterPresets.gapLabel(value)).tag(value)
                        }
                    }

                    Picker("下一词间隔", selection: $nextGap) {
                        ForEach(ParameterPresets.gapOptions(including: nextGap), id: \.self) { value in
                            Text(ParameterPresets.gapLabel(value)).tag(value)
                        }
                    }
                    .disabled(manual)

                    Toggle("手动推进", isOn: $manual)
                } header: {
                    Text("播报节奏")
                } footer: {
                    Text("这是全局默认。单个词库、单条词条还可以再单独覆盖一层。")
                }

                Section {
                    Picker("语音", selection: $voice) {
                        Text("系统默认").tag("")
                        ForEach(store.watchVoices) { item in
                            Text(item.name).tag(item.id)
                        }
                        if !voice.isEmpty && !store.watchVoices.contains(where: { $0.id == voice }) {
                            Text("当前选择（手表上未找到）").tag(voice)
                        }
                    }

                    HStack {
                        Text("语速")
                        Slider(value: $rate, in: 0.30...0.60, step: 0.05)
                        Text(String(format: "%.2f", rate))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                } header: {
                    Text("声音")
                } footer: {
                    if store.watchVoices.isEmpty {
                        Text("先在手表上打开一次 App，这里就会列出手表实际可用的中文语音。")
                    } else {
                        Text("列表来自手表，只有手表上装了的语音才播得出来。增强语音需在手表「设置 > 辅助功能 > 朗读内容 > 语音」下载。")
                    }
                }

                Section {
                    Toggle("省电模式", isOn: $powerSaving)
                } header: {
                    Text("续航")
                } footer: {
                    if powerSaving {
                        Text("念完一个词就停掉保活音频，把音频管线和蓝牙从持续传输里解放出来——这一项是一轮耗电的主体。代价：间隔与暂停期间耳机键不响应，手表熄屏后听写会停住，抬腕自动续上。手动推进模式不受影响。改动下一轮生效。")
                    } else {
                        Text("关闭时全程保持一条静音音频，耳机键随时可用（默认）。想试试能省多少，打开它跑一轮，对比日志里的电量曲线。")
                    }
                }

                Section {
                    LabeledContent("手表已生效", value: store.watchStateSummary)
                    LabeledContent("最近通信", value: store.lastContactText)
                    LabeledContent("同步状态", value: store.syncStatus.text)
                    Button {
                        store.syncToWatch(force: true)
                    } label: {
                        Label("立即推送一次", systemImage: "arrow.up.to.line")
                    }
                    .disabled(store.syncStatus == .sending)
                } header: {
                    Text("同步")
                } footer: {
                    Text("侧载安装时系统的「已安装 / 可达」两项不可信，以「手表已生效」为准。手表 App 没打开时，改动会排队，等你下次打开手表 App 自动送达。")
                }
            }
            .navigationTitle("播报设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并同步") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let p = store.settings.global.merged(over: ParameterResolver.absoluteDefault)
        repeatCount = max(1, min(5, p.repeatCount ?? 2))
        sameGap = p.sameWordGap ?? 3
        nextGap = p.nextWordGap ?? 5
        manual = p.isManualAdvance ?? false
        voice = store.settings.voiceIdentifier ?? ""
        rate = store.settings.speechRate
        powerSaving = store.settings.powerSaving
    }

    private func save() {
        store.updateSettings { settings in
            settings.global = ParameterLayer(repeatCount: repeatCount,
                                             sameWordGap: sameGap,
                                             nextWordGap: nextGap,
                                             isManualAdvance: manual)
            settings.voiceIdentifier = voice.isEmpty ? nil : voice
            settings.speechRate = rate
            settings.powerSaving = powerSaving
        }
        store.saveAndSync()
        dismiss()
    }
}

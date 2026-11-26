import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var coordinator: WatchCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var presenting: WordLibrary?
    @State private var showSettings = false
    @State private var lastSheet: AnswerSheet?

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = coordinator.recoverable,
                   let library = store.library(id: snapshot.libraryID) {
                    Section {
                        Button {
                            coordinator.start(library, settings: store.settings, resume: snapshot)
                            presenting = library
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("继续上次")
                                    .font(.headline)
                                Text("\(library.name) · \(snapshot.currentIndex + 1)/\(snapshot.queueEntryIDs.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            coordinator.discardRecovery()
                        } label: {
                            Text("放弃上次进度")
                        }
                    }
                }

                if let sheet = engine.lastAnswerSheet {
                    Section {
                        Button {
                            lastSheet = sheet
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("上一轮答案")
                                    .font(.headline)
                                Text("\(sheet.libraryName) · \(sheet.items.count) 条\(sheet.isComplete ? "" : " · 未完成")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if store.libraries.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有词库")
                                .font(.headline)
                            Text("在 iPhone 上创建并同步后，这里会出现词库。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section {
                        ForEach(store.libraries) { library in
                            Button {
                                coordinator.start(library, settings: store.settings, resume: nil)
                                presenting = library
                            } label: {
                                libraryRow(library)
                            }
                        }
                    } header: {
                        Text("词库")
                    }
                }

                Section {
                    Button {
                        showSettings = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("播报设置", systemImage: "waveform")
                            Text(paramSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let date = store.lastSyncAt {
                        Text("最近同步 \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("腕上听写")
            .fullScreenCover(item: $presenting, onDismiss: {
                // 从听写界面回来：必须重读快照，否则「继续上次」永远不出现。
                coordinator.refreshRecoverable()
            }) { library in
                DictationView(libraryID: library.id)
                    .environmentObject(engine)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showSettings) {
                WatchSpeechSettingsView()
                    .environmentObject(store)
            }
            .sheet(item: $lastSheet) { sheet in
                AnswerSheetView(items: sheet.items,
                                libraryName: sheet.libraryName,
                                elapsed: sheet.elapsed)
            }
        }
        // 三条路都要重读快照，缺一条就会重现"练完回来什么都没有"：
        // ① 首次出现（App 冷启动）；② 从听写界面 dismiss（见 fullScreenCover onDismiss）；
        // ③ 从表盘/后台回到前台（按表冠出去、再回来）。
        .onAppear { coordinator.refreshRecoverable() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                coordinator.refreshRecoverable()
            }
        }
    }

    /// 首页直接显示当前生效的节奏参数，避免用户每次都点进设置才能确认。
    private var paramSummary: String {
        let p = store.settings.global.merged(over: ParameterResolver.absoluteDefault)
        let repeatCount = p.repeatCount ?? 2
        let same = ParameterPresets.gapLabel(p.sameWordGap ?? 3)
        let next = ParameterPresets.gapLabel(p.nextWordGap ?? 5)
        let manual = (p.isManualAdvance ?? false) ? " · 手动" : ""
        return "\(repeatCount) 次 · 间隔 \(same)/\(next)\(manual)"
    }

    private func libraryRow(_ library: WordLibrary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(library.name)
                .font(.headline)
            HStack(spacing: 6) {
                Text("\(library.enabledCount) 条")
                Text("·")
                Text(library.mode.displayName)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 播报设置

/// 手表端设置页。
///
/// 布局约束（watchOS 屏宽只有 184pt 左右）：
/// - 不再用 `Stepper` + `HStack{ Spacer() }` 的写法，label 会被挤到换行/截断；
/// - 每个 Picker 的标题压到 2~4 个字，长标题在手表上必然显示不全；
/// - 选项标签统一用「3 秒 / 2 分钟」，不再拼接「（增强）」这类后缀。
struct WatchSpeechSettingsView: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [SpeechVoice] = []
    @State private var selectedVoice: String = ""
    @State private var rate: Double = 0.45
    /// 反向显示 `AudioSessionController.prefersCompatibility`：
    /// 打开 = 走自有会话（后台常驻 / 耳机键），关闭 = 兼容模式（声音最稳）。
    /// 默认关闭，因为这一档才保证听得见。
    @State private var backgroundKeepAlive = false

    private var global: ParameterLayer { store.settings.global }
    private var repeatCount: Int { max(1, min(5, global.repeatCount ?? 2)) }
    private var sameGap: Double { global.sameWordGap ?? 3 }
    private var nextGap: Double { global.nextWordGap ?? 5 }
    private var manual: Bool { global.isManualAdvance ?? false }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("次数", selection: Binding(get: { repeatCount }, set: { setRepeat($0) })) {
                        ForEach(ParameterPresets.repeatChoices, id: \.self) { value in
                            Text("\(value) 次").tag(value)
                        }
                    }

                    Picker("同词间隔", selection: Binding(get: { sameGap }, set: { setSameGap($0) })) {
                        ForEach(ParameterPresets.gapOptions(including: sameGap), id: \.self) { value in
                            Text(ParameterPresets.gapLabel(value)).tag(value)
                        }
                    }

                    Picker("下一词间隔", selection: Binding(get: { nextGap }, set: { setNextGap($0) })) {
                        ForEach(ParameterPresets.gapOptions(including: nextGap), id: \.self) { value in
                            Text(ParameterPresets.gapLabel(value)).tag(value)
                        }
                    }

                    Toggle("手动推进", isOn: Binding(get: { manual }, set: { setManual($0) }))
                } header: {
                    Text("播报参数")
                } footer: {
                    Text("手动推进开启后，播完一条要按屏幕才继续。")
                        .font(.caption2)
                }

                Section {
                    Picker("语音", selection: Binding(get: { selectedVoice }, set: { setVoice($0) })) {
                        Text("系统默认").tag("")
                        ForEach(voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                        // 手机端可能指定了一个本机已不存在的语音（下载后被删）。
                        // 没有这个兜底 tag，Picker 会显示成空白行。
                        if !selectedVoice.isEmpty && !voices.contains(where: { $0.id == selectedVoice }) {
                            Text("未知语音").tag(selectedVoice)
                        }
                    }

                    HStack {
                        Text("语速")
                        Spacer()
                        Text(String(format: "%.2f", rate))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { rate }, set: { setRate($0) }),
                           in: 0.30...0.60,
                           step: 0.05)
                } header: {
                    Text("声音")
                } footer: {
                    Text("增强语音需在手表「设置 > 辅助功能 > 朗读内容 > 语音」下载。")
                        .font(.caption2)
                }

                Section {
                    Toggle("后台保活", isOn: Binding(
                        get: { backgroundKeepAlive },
                        set: { newValue in
                            backgroundKeepAlive = newValue
                            // 反向映射：打开"后台保活"= 不要兼容模式 = 走自有会话。
                            AudioSessionController.prefersCompatibility = !newValue
                        }
                    ))
                } header: {
                    Text("播放引擎")
                } footer: {
                    Text(backgroundKeepAlive
                         ? "正在用自有音频会话：可后台常驻、耳机键可用，但本机可能完全没声音。下一轮生效。"
                         : "用系统自带会话发音，声音最稳。代价是耳机键失效，熄屏后可能停下。下一轮生效。")
                        .font(.caption2)
                }

                Section {
                    if let date = store.lastSyncAt {
                        HStack {
                            Text("上次同步")
                            Spacer()
                            Text(date.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("尚未从手机同步")
                            .foregroundStyle(.secondary)
                    }
                    Text("在 iPhone 上改参数并同步，会覆盖这里的设置。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("同步")
                }
            }
            .navigationTitle("播报设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: 读写

    private func load() {
        voices = SystemSpeechService.availableSystemVoices()
        selectedVoice = store.settings.voiceIdentifier ?? ""
        rate = store.settings.speechRate
        backgroundKeepAlive = !AudioSessionController.prefersCompatibility
    }

    private func setRepeat(_ value: Int) {
        apply(repeatCount: max(1, min(5, value)))
    }

    private func setSameGap(_ value: Double) {
        apply(sameWordGap: value)
    }

    private func setNextGap(_ value: Double) {
        apply(nextWordGap: value)
    }

    private func setManual(_ on: Bool) {
        apply(isManualAdvance: on)
    }

    private func apply(repeatCount: Int? = nil,
                       sameWordGap: Double? = nil,
                       nextWordGap: Double? = nil,
                       isManualAdvance: Bool? = nil) {
        let base = global
        store.updateGlobal(ParameterLayer(
            repeatCount: repeatCount ?? base.repeatCount,
            sameWordGap: sameWordGap ?? base.sameWordGap,
            nextWordGap: nextWordGap ?? base.nextWordGap,
            isManualAdvance: isManualAdvance ?? base.isManualAdvance
        ))
        WatchSyncManager.shared.pushState()
    }

    private func setVoice(_ identifier: String) {
        selectedVoice = identifier
        store.updateVoice(identifier.isEmpty ? nil : identifier)
        WatchSyncManager.shared.pushState()
    }

    private func setRate(_ value: Double) {
        rate = value
        store.updateSpeechRate(value)
        WatchSyncManager.shared.pushState()
    }
}

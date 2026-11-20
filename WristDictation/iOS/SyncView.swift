import SwiftUI

struct SyncView: View {
    @EnvironmentObject var store: IOSStore
    @Environment(\.dismiss) private var dismiss

    @State private var exportedURL: URL?
    @State private var remoteEnabled = PhoneRemoteBridge.shared.isEnabled

    private var totalEntries: Int {
        store.libraries.reduce(0) { $0 + $1.entries.count }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("配对", value: store.isPaired ? "已配对" : "未配对")
                    LabeledContent("最近通信", value: store.lastContactText)
                    LabeledContent("手表已生效", value: store.watchStateSummary)
                    if let state = store.watchState, state.entryCount > 0 {
                        LabeledContent("手表内容", value: "\(state.libraryCount) 个词库 · \(state.entryCount) 条")
                        if let voiceName = state.voiceName {
                            LabeledContent("手表语音", value: voiceName)
                        }
                    }
                } header: {
                    Text("手表")
                } footer: {
                    Text("侧载安装时系统会一直报告「未安装 / 不可达」，但实际数据通道可能是通的。判断标准是「最近通信」和「手表已生效」。")
                }

                Section {
                    Button {
                        store.syncToWatch(force: true)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.to.line")
                            Text("立即同步到手表")
                            Spacer()
                            if store.syncStatus == .sending {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.syncStatus == .sending || store.libraries.isEmpty)

                    HStack {
                        Text("状态")
                        Spacer()
                        Text(store.syncStatus.text)
                            .foregroundStyle(store.syncStatus.isError ? .orange : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.footnote)

                    if let date = store.lastSyncAt {
                        LabeledContent("上次成功同步", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let rtt = store.lastRTT {
                        LabeledContent("往返耗时", value: rtt < 1000 ? "\(rtt) 毫秒" : String(format: "%.1f 秒", Double(rtt) / 1000))
                    }
                    LabeledContent("数据版本", value: "v\(store.dataVersion)")
                    LabeledContent("待同步内容", value: "\(store.libraries.count) 个词库 · \(totalEntries) 条")
                } header: {
                    Text("同步")
                } footer: {
                    Text("同步会把全部词库一次性覆盖到手表。手表以最后一次完整成功的数据为准，中途失败不会破坏手表上已有的词库。")
                }

                if !store.watchVoices.isEmpty {
                    Section("手表可用语音") {
                        ForEach(store.watchVoices) { voice in
                            HStack {
                                Text(voice.name)
                                Spacer()
                                Text("\(voice.language) · \(voice.qualityLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if let url = exportedURL {
                        ShareLink(item: url) {
                            Label("导出词库 JSON", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("准备导出…") {
                            prepareExport()
                        }
                        .disabled(store.libraries.isEmpty)
                    }
                } header: {
                    Text("备份")
                } footer: {
                    Text("导出的 JSON 可以在重装应用后重新导入，也可以用来手工编辑。")
                }

                Section {
                    LabeledContent("词库数", value: "\(store.libraries.count)")
                    LabeledContent("词条总数", value: "\(totalEntries)")
                } header: {
                    Text("内容")
                }

                Section {
                    LabeledContent("系统标记",
                                   value: "已安装 \(store.isWatchAppInstalled ? "是" : "否") · 可达 \(store.isReachable ? "是" : "否")")
                } footer: {
                    Text("这两项由系统的安装登记表决定，侧载 App 常常恒为「否」。它只影响提示，不影响已经打通的数据通道。")
                }

                Section {
                    Toggle("手机遥控（耳机连手机时）", isOn: Binding(
                        get: { remoteEnabled },
                        set: { newValue in
                            remoteEnabled = newValue
                            PhoneRemoteBridge.shared.isEnabled = newValue
                        }
                    ))
                } footer: {
                    Text("开启后，AirPods 连在 iPhone 上时，单击/双击/三击会转发给手表执行。若耳机主要连手表，请保持关闭，避免同一手势被处理两次。")
                }
            }
            .navigationTitle("手表同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                store.refreshSessionState()
                prepareExport()
            }
        }
    }

    private func prepareExport() {
        guard exportedURL == nil, let data = store.exportArchiveData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("腕上听写备份.json")
        try? data.write(to: url, options: .atomic)
        exportedURL = url
    }
}

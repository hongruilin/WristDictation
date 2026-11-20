import SwiftUI

struct WordEditorView: View {
    let libraryID: UUID
    let entry: VocabularyEntry

    @EnvironmentObject var store: IOSStore
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var isEnabled: Bool = true

    @State private var overrideRepeat = false
    @State private var repeatCount = 2
    @State private var overrideSame = false
    @State private var sameGapText = ""
    @State private var overrideNext = false
    @State private var nextGapText = ""
    @State private var overrideManual = false
    @State private var manualAdvance = false

    @State private var inheritedText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("词条") {
                    TextField("内容", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("参加播放", isOn: $isEnabled)
                }

                Section {
                    paramRow(title: "播报次数",
                             isOn: $overrideRepeat,
                             inherited: inheritedText,
                             editor: {
                                 Stepper("\(repeatCount) 次",
                                         value: $repeatCount,
                                         in: ParameterLimits.repeatCountRange)
                             })
                } header: {
                    Text("播报参数")
                } footer: {
                    Text("顺序和随机都按这套参数执行；随机只改变播报顺序，不改次数与间隔。")
                }

                Section {
                    paramRow(title: "同词重复间隔",
                             isOn: $overrideSame,
                             inherited: inheritedText,
                             editor: {
                                 HStack {
                                     TextField("秒", text: $sameGapText)
                                         .keyboardType(.decimalPad)
                                     Text("秒").foregroundStyle(.secondary)
                                 }
                             })

                    paramRow(title: "下一词间隔",
                             isOn: $overrideNext,
                             inherited: inheritedText,
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
                             inherited: inheritedText,
                             editor: {
                                 Toggle("播完后等待手动切换", isOn: $manualAdvance)
                             })
                } footer: {
                    Text("开启「手动推进」后，这条播完不会自动进入下一条，由你按下一条继续。")
                }

                Section {
                    Button("恢复为全部继承", role: .destructive) {
                        overrideRepeat = false
                        overrideSame = false
                        overrideNext = false
                        overrideManual = false
                        manualAdvance = false
                    }
                }
            }
            .navigationTitle("编辑词条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
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
                Text("沿用词库默认：\(inherited)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 读写

    private func load() {
        text = entry.text
        isEnabled = entry.isEnabled

        if let library = store.library(id: libraryID) {
            let resolved = ParameterResolver.resolve(settings: store.settings, library: library, entry: entry)
            inheritedText = "×\(resolved.repeatCount) · 同词 \(ParameterLimits.formatGap(resolved.sameWordGap))s · "
                + (resolved.isManualAdvance ? "手动" : "下词 \(ParameterLimits.formatGap(resolved.nextWordGap))s")
        }

        let o = entry.overrides
        if let value = o.repeatCount {
            overrideRepeat = true
            repeatCount = value
        }
        if let value = o.sameWordGap {
            overrideSame = true
            sameGapText = ParameterLimits.formatGap(value)
        }
        if let value = o.nextWordGap {
            overrideNext = true
            nextGapText = ParameterLimits.formatGap(value)
        }
        if let value = o.isManualAdvance {
            overrideManual = true
            manualAdvance = value
        }
    }

    private func save() {
        var layer = ParameterLayer()

        if overrideRepeat {
            layer.repeatCount = ParameterLimits.clampRepeat(repeatCount)
        }
        if overrideSame, let value = Double(sameGapText.trimmingCharacters(in: .whitespaces)) {
            layer.sameWordGap = ParameterLimits.clampGap(value)
        }
        if overrideNext, !manualAdvance, let value = Double(nextGapText.trimmingCharacters(in: .whitespaces)) {
            layer.nextWordGap = ParameterLimits.clampGap(value)
        }
        if overrideManual {
            layer.isManualAdvance = manualAdvance
        }

        var updated = entry
        updated.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.isEnabled = isEnabled
        updated.overrides = layer
        store.updateEntry(libraryID: libraryID, entry: updated)
        dismiss()
    }
}

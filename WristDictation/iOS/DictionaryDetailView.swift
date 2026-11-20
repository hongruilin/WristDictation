import SwiftUI

struct DictionaryDetailView: View {
    let libraryID: UUID

    @EnvironmentObject var store: IOSStore

    @State private var editingEntry: VocabularyEntry?
    @State private var showImport = false
    @State private var showSettings = false
    @State private var showAdd = false
    @State private var showBatchPaste = false
    @State private var newText = ""

    var body: some View {
        Group {
            if let library = store.library(id: libraryID) {
                content(library)
            } else {
                ContentUnavailableView("词库已删除", systemImage: "trash")
            }
        }
    }

    private func content(_ library: WordLibrary) -> some View {
        List {
            Section {
                ForEach(library.entries) { entry in
                    Button {
                        editingEntry = entry
                    } label: {
                        entryRow(entry, library: library)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.deleteEntries(libraryID: libraryID, ids: [entry.id])
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { library.entries[$0].id }
                    store.deleteEntries(libraryID: libraryID, ids: Set(ids))
                }
                .onMove { source, destination in
                    store.moveEntries(libraryID: libraryID, from: source, to: destination)
                }

                Button {
                    newText = ""
                    showAdd = true
                } label: {
                    Label("添加一条", systemImage: "plus.circle")
                }

                Button {
                    showBatchPaste = true
                } label: {
                    Label("批量粘贴（一行一条）", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("词条（\(library.enabledCount) / \(library.entries.count) 启用）")
            } footer: {
                if library.entries.isEmpty {
                    Text("还没有词条。可以手动加一条、整段粘贴，或点右上角从文件导入。")
                } else {
                    Text("点按行可编辑该条的播报参数；左滑删除；点右上角「编辑」可拖动排序。")
                }
            }

            Section {
                Button {
                    showSettings = true
                } label: {
                    Label("词库播报设置", systemImage: "slider.horizontal.3")
                }
                Button {
                    showImport = true
                } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button {
                    showImport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            WordEditorView(libraryID: libraryID, entry: entry)
                .environmentObject(store)
        }
        .sheet(isPresented: $showImport) {
            ImportSheet(libraryID: libraryID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showBatchPaste) {
            BatchPasteSheet(libraryID: libraryID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            LibrarySettingsView(libraryID: libraryID)
                .environmentObject(store)
        }
        .alert("添加词条", isPresented: $showAdd) {
            TextField("单字、词语、成语或短句", text: $newText)
            Button("添加") {
                store.addEntry(libraryID: libraryID, text: newText)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("一条词目可以包含标点，会按原样朗读。")
        }
    }

    private func entryRow(_ entry: VocabularyEntry, library: WordLibrary) -> some View {
        let resolved = ParameterResolver.resolve(settings: store.settings, library: library, entry: entry)
        return HStack(spacing: 10) {
            Button {
                store.toggleEntry(libraryID: libraryID, entryID: entry.id)
            } label: {
                Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.isEnabled ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                    .strikethrough(!entry.isEnabled, color: .secondary)
                Text(summary(resolved))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if !entry.overrides.isEmpty {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func summary(_ p: ResolvedParameters) -> String {
        var parts = ["×\(p.repeatCount)"]
        parts.append("同词 \(ParameterLimits.formatGap(p.sameWordGap))s")
        parts.append(p.isManualAdvance ? "手动推进" : "下词 \(ParameterLimits.formatGap(p.nextWordGap))s")
        return parts.joined(separator: " · ")
    }
}

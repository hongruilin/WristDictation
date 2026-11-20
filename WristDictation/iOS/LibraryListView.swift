import SwiftUI

struct LibraryListView: View {
    @EnvironmentObject var store: IOSStore

    @State private var newLibraryName = ""
    @State private var showNewLibrary = false
    @State private var showSync = false
    @State private var showSettings = false
    @State private var pendingDelete: WordLibrary?

    var body: some View {
        NavigationStack {
            List {
                if store.syncStatus.isError {
                    Section {
                        syncBanner
                    }
                }

                Section {
                    ForEach(store.libraries) { library in
                        NavigationLink(value: library.id) {
                            row(library)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = library
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("词库（\(store.libraries.count)）")
                } footer: {
                    Text("手表会保存全部词库，可以直接在手表上切换。")
                }

                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label("播报设置（节奏 / 语音 / 语速）", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("在这里改，改完自动推送到手表；手表上也会显示当前生效值。")
                }
            }
            .navigationTitle("腕上听写")
            .navigationDestination(for: UUID.self) { id in
                DictionaryDetailView(libraryID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSync = true
                        store.refreshSessionState()
                    } label: {
                        Image(systemName: "applewatch")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newLibraryName = ""
                        showNewLibrary = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showSync) {
                SyncView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showSettings) {
                GlobalSettingsView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showNewLibrary) {
                newLibrarySheet
            }
            .alert("删除词库", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let lib = pendingDelete {
                        store.deleteLibrary(id: lib.id)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("「\(pendingDelete?.name ?? "")」及其 \(pendingDelete?.entries.count ?? 0) 条词条将被删除，手表上的副本会在下次同步后同步删除。")
            }
        }
    }

    private var syncBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(store.syncStatus.text)
                .font(.footnote)
            Spacer()
            Button("重试") {
                store.syncToWatch(force: true)
            }
            .font(.footnote)
        }
    }

    private func row(_ library: WordLibrary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(library.name)
                .font(.headline)
            HStack(spacing: 8) {
                Text("\(library.entries.count) 条")
                Text("启用 \(library.enabledCount)")
                Text(library.mode.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var newLibrarySheet: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：中考易错成语", text: $newLibraryName)
                }
                Section {
                    Text("创建后可以手动添加词条，或从 TXT / CSV / JSON 导入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建词库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showNewLibrary = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        store.addLibrary(name: newLibraryName)
                        showNewLibrary = false
                    }
                    .disabled(newLibraryName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

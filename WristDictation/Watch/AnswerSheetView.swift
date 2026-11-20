import SwiftUI

/// 本轮答案单：按**实际播放顺序**列出词条。
/// 随机模式下这是用户唯一能看到顺序的地方（PRD 7.4）。
struct AnswerSheetView: View {
    let items: [PlayedItem]
    let libraryName: String
    let elapsed: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Text("\(item.order)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)

                            Text(item.text)
                                .font(.system(size: 15, weight: .medium))
                                .lineLimit(2)

                            Spacer(minLength: 2)

                            if item.plays > 1 {
                                Text("×\(item.plays)")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                } header: {
                    Text("\(libraryName) · \(items.count) 条 · \(elapsed)")
                        .font(.caption2)
                }
            }
            .navigationTitle("本轮答案")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI

/// 热词词库多选弹窗
struct HotwordPresetPickerSheet: View {
    @Binding var selectedIds: Set<String>
    var onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let categories = HotwordPresetsManager.shared.categories

    /// 所有可选类别（行业词库 + 全局自定义热词）
    private var allCategories: [HotwordCategory] {
        var list = categories
        let customStr = SettingsManager.shared.hotwords.trimmingCharacters(in: .whitespaces)
        let words = customStr.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let customCat = HotwordCategory(
            id: "__custom__",
            name: "自定义热词",
            words: words
        )
        list.insert(customCat, at: 0)
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择行业词库")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(selectedIds.isEmpty
                         ? "未选择任何词库"
                         : "已选 \(selectedIds.count) 组")
                        .font(.caption)
                        .foregroundStyle(selectedIds.isEmpty ? Color.secondary : Color.purple)
                }
                Spacer()
                Button {
                    onDismiss()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // 快捷操作行
            HStack(spacing: 12) {
                Button("全选") {
                    selectedIds = Set(allCategories.map { $0.id })
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("清空") {
                    selectedIds = []
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // 词库列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(allCategories, id: \.id) { category in
                        let isSelected = selectedIds.contains(category.id)
                        Button {
                            if isSelected {
                                selectedIds.remove(category.id)
                            } else {
                                selectedIds.insert(category.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.body)
                                    .foregroundStyle(isSelected ? Color.purple : Color.secondary.opacity(0.5))
                                    .frame(width: 20)

                                Text(category.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 8)

                                let wordCount = category.words.count
                                Text("\(wordCount) 个热词")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .layoutPriority(1)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(isSelected
                                        ? Color.purple.opacity(0.06)
                                        : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if category.id != allCategories.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }

            Divider()

            // 底部确认按钮
            Button {
                onDismiss()
                dismiss()
            } label: {
                Text(selectedIds.isEmpty ? "确认（不使用词库）" : "确认选择 \(selectedIds.count) 组词库")
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectedIds.isEmpty ? Color.primary.opacity(0.08) : Color.purple)
                    .foregroundStyle(selectedIds.isEmpty ? Color.primary : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 360, height: 500)
        .background(.regularMaterial)
    }
}

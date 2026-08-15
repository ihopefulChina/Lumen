import SwiftUI

struct ObjectPropertiesView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var properties: ObjectPropertiesModel

    var body: some View {
        VStack(spacing: 0) {
            if properties.isLoading {
                ProgressView("正在读取对象属性…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Web 行为") {
                        TextField("Content-Type", text: $properties.draft.contentType)
                        TextField("Cache-Control", text: $properties.draft.cacheControl)
                        TextField("Content-Disposition", text: $properties.draft.contentDisposition)
                    }
                    editableSection(
                        "用户元数据",
                        rows: $properties.draft.metadata,
                        add: { properties.draft.metadata.append(EditableProperty(key: "", value: "")) }
                    )
                    editableSection(
                        "标签",
                        rows: $properties.draft.tags,
                        add: { properties.draft.tags.append(EditableProperty(key: "", value: "")) }
                    )
                    if !properties.draft.validationErrors.isEmpty {
                        Section {
                            ForEach(properties.draft.validationErrors, id: \.self) { error in
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                if let error = properties.errorMessage {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("修改属性会在已启用版本控制的 Bucket 中产生新版本。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("存储") {
                    Task { if await properties.save() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!properties.canSave)
            }
            .font(.callout)
            .padding(14)
        }
        .frame(minWidth: 620, minHeight: 520)
        .navigationTitle("“\(properties.object.name)”的属性")
        .task { await properties.load() }
    }

    private func editableSection(
        _ title: String,
        rows: Binding<[EditableProperty]>,
        add: @escaping () -> Void
    ) -> some View {
        Section(title) {
            ForEach(rows) { $row in
                HStack {
                    TextField("键", text: $row.key)
                    TextField("值", text: $row.value)
                    Button {
                        rows.wrappedValue.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除")
                }
            }
            Button("添加", systemImage: "plus") { add() }
                .disabled(title == "标签" && rows.wrappedValue.count >= 10)
        }
    }
}

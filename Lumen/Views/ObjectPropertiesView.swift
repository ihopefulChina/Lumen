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
                    Section {
                        Text("这些是这个对象在 OSS 上的 HTTP 元数据和标签。点“保存”后立即写回云端，链接、下载文件名和缓存行为会按新值生效。")
                            .foregroundStyle(.secondary)
                    }
                    Section("打开与下载") {
                        TextField("文件类型", text: $properties.draft.contentType, prompt: Text("例如 image/jpeg"))
                        TextField("缓存", text: $properties.draft.cacheControl, prompt: Text("例如 max-age=3600"))
                        TextField("下载文件名", text: $properties.draft.contentDisposition, prompt: Text("例如 attachment; filename=\"封面.jpg\""))
                    }
                    editableSection(
                        "自定义元数据",
                        rows: $properties.draft.metadata,
                        add: { properties.draft.metadata.append(EditableProperty(key: "", value: "")) }
                    )
                    if properties.tagsUnavailable {
                        Section("标签") {
                            Text("当前账号没有读取标签的权限，标签未改动。")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        editableSection(
                            "标签",
                            rows: $properties.draft.tags,
                            add: { properties.draft.tags.append(EditableProperty(key: "", value: "")) }
                        )
                    }
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
                Button("保存") {
                    Task { if await properties.save() { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
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
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除")
                }
            }
            Button("添加", systemImage: "plus") { add() }
                .disabled(title == "标签" && rows.wrappedValue.count >= 10)
        }
    }
}

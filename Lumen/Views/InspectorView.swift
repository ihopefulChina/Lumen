import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let object = model.browser.primarySelection {
                objectInfo(object)
            } else if model.selectedBucket != nil {
                folderInfo
            } else {
                ContentUnavailableView("没有选择", systemImage: "info.circle", description: Text("选中图片、JSON 或文本后，这里会显示详情。"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func objectInfo(_ object: OSSObject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if object.isText, let text = model.inspectorText {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ThumbnailView(object: object, style: .inspector)
                        .frame(height: object.isImage ? 168 : 96)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(object.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(object.key)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    infoRow("大小", Formatters.bytes(object.size))
                    infoRow("种类", ImageKind.displayKind(for: object.key))
                    infoRow("修改", Formatters.date(object.lastModified))
                    if let head = model.inspectorHead {
                        if let type = head.contentType { infoRow("类型", type) }
                        if let acl = head.acl { infoRow("权限", acl) }
                        if let storage = head.storageClass { infoRow("存储", storage) }
                    }
                }
                .font(.callout)

                if let account = model.selectedAccount,
                   let bucket = model.selectedBucket,
                   let url = account.publicURL(bucketName: bucket.name, bucket: bucket, key: object.key) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("链接")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(4)
                        HStack {
                            Button("复制链接") { model.copyURLs(style: .plain) }
                            Button("Markdown") { model.copyURLs(style: .markdown) }
                        }
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Button("快速查看") {
                        Task { await model.quickLookSelection() }
                    }
                    Button("下载") {
                        model.downloadSelection()
                    }
                    Spacer()
                    Button("删除", role: .destructive) {
                        model.requestDeleteSelection()
                    }
                    .tint(.red)
                }
                .controlSize(.regular)
            }
        }
    }

    private var folderInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.browser.prefix.isEmpty ? (model.selectedBucket?.name ?? "存储空间") : PathTemplate.lastComponent(model.browser.prefix))
                .font(.title3.weight(.semibold))
            Text(model.browser.prefix.isEmpty ? "/" : "/" + model.browser.prefix)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                infoRow("文件夹", "\(model.browser.folders.count)")
                infoRow("对象", "\(model.browser.objects.count)")
                if let region = model.selectedBucket?.regionLabel {
                    infoRow("地域", region)
                }
            }
            .font(.callout)
            Text("把图片、JSON 或文本拖进窗口，就会上传到这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

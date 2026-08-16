import SwiftUI

struct CrossBucketPreflightView: View {
    @Environment(\.dismiss) private var dismiss
    let preflight: CrossBucketPreflight
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: preflight.mode == .move ? "folder.badge.gearshape" : "doc.on.doc")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preflight.mode == .move ? "移动到另一个 Bucket" : "复制到另一个 Bucket")
                        .font(.title2.weight(.semibold))
                    Text("请确认来源、目标和传输方式。")
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                row("来源", "\(preflight.sourceAccount.displayName) / \(preflight.sourceBucket.name)")
                row("目标", "\(preflight.destinationAccount.displayName) / \(preflight.destinationBucket.name)")
                row("项目", "\(preflight.plan.mappings.count) 个对象")
                row("已知大小", Formatters.bytes(preflight.plan.knownBytes))
                row("方式", preflight.plan.method.title)
                if preflight.renamedConflicts > 0 {
                    row("同名项目", "保留两者（\(preflight.renamedConflicts) 项已重新命名）")
                }
            }

            if preflight.plan.method == .relay {
                Label("数据会先下载到这台 Mac 的临时目录，再上传到目标 Bucket。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(preflight.mode == .move ? "移动" : "复制") {
                    dismiss()
                    confirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

import AppKit
import SwiftUI

struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lumen \(release.version) 已发布")
                        .font(.title2.weight(.semibold))
                    Text("当前版本 \(AppVersion.current)")
                        .foregroundStyle(.secondary)
                }
            }

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let message = model.updates.lastMessage,
               model.updates.isDownloading || model.updates.lastOperationFailed {
                Label(
                    message,
                    systemImage: model.updates.lastOperationFailed ? "exclamationmark.triangle" : "arrow.down.circle"
                )
                .font(.callout)
                .foregroundStyle(model.updates.lastOperationFailed ? Color.red : Color.secondary)
            }

            HStack {
                Button("忽略此版本") {
                    model.updates.skipAvailable()
                }
                .disabled(model.updates.isDownloading)
                Spacer()
                Button("稍后") {
                    model.updates.dismissAvailable()
                }
                .disabled(model.updates.isDownloading)
                if release.dmgURL != nil {
                    Button {
                        Task { await model.updates.downloadAndOpen() }
                    } label: {
                        if model.updates.isDownloading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 8)
                        } else {
                            Text("下载并打开")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.updates.isDownloading)
                } else {
                    Button("打开发布页") {
                        model.updates.openReleasePage()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

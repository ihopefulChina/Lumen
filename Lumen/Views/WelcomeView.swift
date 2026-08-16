import AppKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text("欢迎使用 Lumen")
                    .font(.largeTitle.weight(.semibold))
                    .tracking(-0.6)
                Text("把素材图片送到阿里云 OSS")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button("添加账号…") {
                model.editingAccount = nil
                model.showAccountSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

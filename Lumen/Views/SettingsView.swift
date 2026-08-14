import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section("上传") {
                    Stepper(value: $model.settings.concurrentUploads, in: 1...6) {
                        Text("同时上传 \(model.settings.concurrentUploads) 个文件")
                    }
                    Toggle("将 HEIC 转为 JPEG", isOn: $model.settings.convertHEIC)
                    Toggle("只显示和上传素材（图片、JSON、文本）", isOn: $model.settings.imagesOnly)
                        .onChange(of: model.settings.imagesOnly) { _, value in
                            model.browser.imagesOnly = value
                        }
                }
                Section("完成时") {
                    Toggle("播放提示音", isOn: $model.settings.playCompleteSound)
                    Toggle("传输时显示菜单栏图标", isOn: $model.settings.showMenuBarWhileTransferring)
                }
                Section("关于") {
                    LabeledContent("Lumen", value: Self.shortVersion)
                    Text("传图片和文本去阿里云 OSS。密钥只存在这台 Mac 上。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gear") }

            Form {
                Section("已保存的账号") {
                    if model.accounts.isEmpty {
                        Text("还没有账号")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.accounts) { account in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(account.displayName)
                                    Text("\(account.region.name) · \(account.accessKeyId)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("编辑") {
                                    model.editingAccount = account
                                    model.showAccountSheet = true
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("账号", systemImage: "person.crop.circle") }
        }
        .padding(8)
    }

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }
}

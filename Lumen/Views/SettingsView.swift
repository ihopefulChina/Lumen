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
                    Toggle("只显示和上传素材（含 GIF / WebP / SVG）", isOn: $model.settings.imagesOnly)
                        .onChange(of: model.settings.imagesOnly) { _, value in
                            for session in AppServices.shared.sessions {
                                session.browser.imagesOnly = value
                            }
                        }
                }
                Section("完成时") {
                    Toggle("播放提示音", isOn: $model.settings.playCompleteSound)
                    Toggle("传输时显示菜单栏图标", isOn: $model.settings.showMenuBarWhileTransferring)
                        .onChange(of: model.settings.showMenuBarWhileTransferring) { _, enabled in
                            model.showMenuBarExtra = enabled && model.transfers.activeCount > 0
                        }
                }
                Section("更新") {
                    LabeledContent("当前版本", value: AppVersion.current)
                    Toggle("自动检查更新", isOn: Binding(
                        get: { model.settings.checkUpdatesAutomatically },
                        set: { enabled in
                            model.settings.checkUpdatesAutomatically = enabled
                            model.updates.automaticallyChecksForUpdates = enabled
                        }
                    ))
                    Button("检查更新…") {
                        model.updates.checkForUpdates()
                    }
                    .disabled(!model.updates.canCheckForUpdates)
                    Text("发现新版本后可直接安装；安装完成后，Lumen 会自动重新打开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    Text("传图片和文本去阿里云 OSS。密钥只存在这台 Mac 上。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link("GitHub 仓库", destination: AppLinks.github)
                    Link("发布页", destination: AppLinks.releases)
                    Link("问题与反馈", destination: AppLinks.issues)
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
                                    Text(account.region.name)
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
}

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
                }
                Section("更新") {
                    LabeledContent("当前版本", value: AppVersion.current)
                    Toggle("自动检查更新", isOn: $model.settings.checkUpdatesAutomatically)
                    HStack {
                        Button("检查更新…") {
                            Task {
                                await model.updates.check(manual: true, surface: .settings)
                                if model.updates.available == nil {
                                    WindowActions.notify(model.updates.lastMessage ?? "检查完成")
                                }
                            }
                        }
                        .disabled(model.updates.isChecking || model.updates.isDownloading)
                        if model.updates.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if let message = model.updates.lastMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let checked = model.updates.lastChecked {
                        Text("上次检查：\(Formatters.date(checked))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .sheet(item: Binding(
            get: { model.updates.surface == .settings ? model.updates.available : nil },
            set: { if $0 == nil { model.updates.dismissAvailable() } }
        )) { release in
            UpdateSheet(release: release)
                .environment(model)
        }
    }
}

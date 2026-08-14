import SwiftUI

struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var draft: AccountDraft
    @State private var isTesting = false
    @State private var errorText: String?
    @State private var showAdvanced = false
    @State private var showSecret = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    TextField("名称", text: $draft.name, prompt: Text("工作室、主账号…"))
                    TextField("AccessKey ID", text: $draft.accessKeyId)
                        .textContentType(.username)
                    HStack {
                        Group {
                            if showSecret {
                                TextField("AccessKey Secret", text: $draft.secret)
                            } else {
                                SecureField("AccessKey Secret", text: $draft.secret)
                            }
                        }
                        .textContentType(.password)
                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showSecret ? "隐藏密钥" : "显示密钥")
                    }
                }

                Section("存储位置") {
                    Picker("地域", selection: $draft.regionID) {
                        ForEach(OSSRegion.all) { region in
                            Text(region.name).tag(region.id)
                        }
                    }
                    Toggle("传输加速", isOn: $draft.useTransferAccelerate)
                    Picker("默认权限", selection: $draft.defaultACL) {
                        ForEach(ObjectACL.allCases) { acl in
                            Text(acl.title).tag(acl)
                        }
                    }
                    Text(draft.defaultACL.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("上传路径") {
                    TextField("路径模板", text: $draft.prefixTemplate, prompt: Text("assets/{yyyy}/{MM}/{dd}/"))
                    Text("留空则传到当前文件夹。可用 {yyyy} {MM} {dd} {filename}。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("高级", isExpanded: $showAdvanced) {
                        TextField("STS Token", text: $draft.token)
                        TextField("自定义 Endpoint", text: $draft.endpointOverride, prompt: Text("oss-cn-hangzhou.aliyuncs.com"))
                        TextField("CDN 域名", text: $draft.cdnDomain, prompt: Text("cdn.example.com"))
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.editingAccount == nil ? "添加账号" : "编辑账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isTesting ? "正在连接…" : "存储并连接") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isTesting)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .task {
            if let account = model.editingAccount {
                let secret = SecretStore.get(account: AccountStore.secretAccount(account.id)) ?? ""
                let token = SecretStore.get(account: AccountStore.tokenAccount(account.id)) ?? ""
                draft = AccountDraft.from(account, secret: secret, token: token)
            }
        }
    }

    private var canSave: Bool {
        !draft.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.secret.isEmpty
    }

    private func save() async {
        isTesting = true
        errorText = nil
        do {
            try await model.saveAccount(draft)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        isTesting = false
    }
}

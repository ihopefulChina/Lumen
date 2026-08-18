import SwiftUI

struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var draft: AccountDraft
    @State private var isTesting = false
    @State private var errorText: String?
    @State private var showAdvanced = false
    @State private var showSecret = false
    @State private var showToken = false
    @State private var pendingACL: ObjectACL?
    @State private var showACLConfirmation = false

    /// Editing must start with the persisted account identity before any
    /// Keychain lookup. A Keychain error must never leave an edit sheet backed
    /// by a fresh UUID, otherwise re-entering the credentials would append a
    /// duplicate account instead of updating the selected one.
    static func initialDraft(editing account: OSSAccount?) -> AccountDraft {
        guard let account else { return .fresh() }
        return .from(account, secret: "", token: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section("账号信息") {
                    TextField("显示名称", text: $draft.name, prompt: Text("工作室、主账号…"))
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
                        .privacySensitive()
                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showSecret ? "隐藏密钥" : "显示密钥")
                        .accessibilityLabel(showSecret ? "隐藏 AccessKey Secret" : "显示 AccessKey Secret")
                    }
                }

                Section("存储空间") {
                    Picker("地域", selection: $draft.regionID) {
                        ForEach(OSSRegion.all) { region in
                            Text(region.name).tag(region.id)
                        }
                    }
                    Toggle("传输加速", isOn: $draft.useTransferAccelerate)
                    Picker("默认权限", selection: aclSelection) {
                        ForEach(commonACLs) { acl in
                            Text(acl.title).tag(acl)
                        }
                    }
                    Text(draft.defaultACL.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if draft.defaultACL.isPublic {
                        Label("公开权限会允许通过公网链接读取对象，请只用于明确需要公开分发的内容。", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("权限警告：对象可通过公网链接读取")
                    }
                }

                Section("上传") {
                    TextField("路径模板", text: $draft.prefixTemplate, prompt: Text("assets/{yyyy}/{MM}/{dd}/"))
                    Text("留空则传到当前文件夹。可用 {yyyy} {MM} {dd} {filename}。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("高级", isExpanded: $showAdvanced) {
                        HStack {
                            Group {
                                if showToken {
                                    TextField("STS Token", text: $draft.token)
                                } else {
                                    SecureField("STS Token", text: $draft.token)
                                }
                            }
                            .textContentType(.password)
                            .privacySensitive()
                            Button {
                                showToken.toggle()
                            } label: {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showToken ? "隐藏 STS Token" : "显示 STS Token")
                            .accessibilityLabel(showToken ? "隐藏 STS Token" : "显示 STS Token")
                        }
                        TextField("自定义 Endpoint", text: $draft.endpointOverride, prompt: Text("oss-cn-hangzhou.aliyuncs.com"))
                        TextField("CDN 域名", text: $draft.cdnDomain, prompt: Text("cdn.example.com"))
                        Button("使用公共读写权限…", role: .destructive) {
                            proposeACL(.publicReadWrite)
                        }
                        .disabled(draft.defaultACL == .publicReadWrite)
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在验证连接…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.editingAccount == nil ? "连接" : "保存") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isTesting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(
            minWidth: 540,
            idealWidth: 560,
            maxWidth: 620,
            minHeight: 600,
            idealHeight: 650,
            maxHeight: 760
        )
        .confirmationDialog(
            pendingACL?.title ?? "确认公开权限",
            isPresented: $showACLConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认使用\(pendingACL?.title ?? "公开权限")") {
                if let pendingACL {
                    draft.defaultACL = pendingACL
                }
                self.pendingACL = nil
            }
            Button("取消", role: .cancel) {
                pendingACL = nil
            }
        } message: {
            if let pendingACL {
                Text(AccountACLConfirmation.message(for: pendingACL))
            }
        }
        .task(id: model.editingAccount?.id) {
            if let account = model.editingAccount {
                // Keep this defensive assignment even though every production
                // caller uses initialDraft(editing:). It preserves the existing
                // account ID if a future caller accidentally supplies .fresh().
                if draft.id != account.id {
                    draft = Self.initialDraft(editing: account)
                }
                do {
                    let secret = try SecretStore.read(account: AccountStore.secretAccount(account.id)) ?? ""
                    draft.secret = secret
                    let token = try SecretStore.read(account: AccountStore.tokenAccount(account.id)) ?? ""
                    draft.token = token
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: model.editingAccount == nil ? "person.crop.circle.badge.plus" : "person.crop.circle")
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.editingAccount == nil ? "添加账号" : "编辑账号")
                    .font(.title2.weight(.semibold))
                Label("密钥只保存在这台 Mac 的钥匙串中", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var canSave: Bool {
        draft.isReadyToSave
    }

    private var commonACLs: [ObjectACL] {
        var values: [ObjectACL] = [.default, .private, .publicRead]
        if draft.defaultACL == .publicReadWrite {
            values.append(.publicReadWrite)
        }
        return values
    }

    private var aclSelection: Binding<ObjectACL> {
        Binding(
            get: { draft.defaultACL },
            set: { proposeACL($0) }
        )
    }

    private func proposeACL(_ acl: ObjectACL) {
        guard AccountACLConfirmation.requiresConfirmation(from: draft.defaultACL, to: acl) else {
            draft.defaultACL = acl
            return
        }
        pendingACL = acl
        showACLConfirmation = true
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

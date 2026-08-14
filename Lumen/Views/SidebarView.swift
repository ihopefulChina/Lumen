import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var accountToDelete: OSSAccount?

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.selectedBucketName },
            set: { name in
                if let name, let bucket = model.buckets.first(where: { $0.name == name }) {
                    model.selectBucket(bucket)
                }
            }
        )) {
            Section("账号") {
                ForEach(model.accounts) { account in
                    Button {
                        model.selectAccount(account)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                    .lineLimit(1)
                                Text(account.region.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: account.id == model.selectedAccountID ? "cloud.fill" : "cloud")
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(account.id == model.selectedAccountID ? Color.accentColor.opacity(0.14) : Color.clear)
                    .contextMenu {
                        Button("编辑…") {
                            model.editingAccount = account
                            model.showAccountSheet = true
                        }
                        Button("删除账号", role: .destructive) {
                            accountToDelete = account
                        }
                    }
                }
            }

            Section("存储空间") {
                if model.isLoadingBuckets {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.buckets.isEmpty {
                    Text("这个账号下还没有 Bucket")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.buckets) { bucket in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bucket.name)
                                    .lineLimit(1)
                                Text(bucket.regionLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "externaldrive")
                        }
                        .tag(bucket.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.editingAccount = nil
                    model.showAccountSheet = true
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .help("添加账号")
            }
        }
        .confirmationDialog(
            "删除账号“\(accountToDelete?.displayName ?? "")”？",
            isPresented: Binding(
                get: { accountToDelete != nil },
                set: { if !$0 { accountToDelete = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let accountToDelete {
                    model.deleteAccount(accountToDelete)
                }
                accountToDelete = nil
            }
            Button("取消", role: .cancel) { accountToDelete = nil }
        } message: {
            Text("只删除这台 Mac 上的登录信息，不会改动云端数据。")
        }
    }
}

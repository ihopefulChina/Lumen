import AppKit
import SwiftUI

struct HelpView: View {
    @State private var topic: HelpTopic? = .gettingStarted
    @State private var copied = false

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $topic) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("Lumen 帮助")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    let selected = topic ?? .gettingStarted
                    Text("lumen / help / \(selected.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(selected.title)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    topicContent(selected)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(32)
                .textSelection(.enabled)
            }
            .navigationTitle(topic?.title ?? "Lumen 帮助")
            .toolbar {
                ToolbarItem {
                    Button {
                        copyDiagnostics()
                    } label: {
                        Label(copied ? "已复制" : "复制诊断信息", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("复制不含账号、Bucket、对象路径或密钥的诊断摘要")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    @ViewBuilder
    private func topicContent(_ topic: HelpTopic) -> some View {
        switch topic {
        case .gettingStarted:
            helpSection("连接 OSS") {
                Text("先在阿里云创建只允许访问所需 Bucket 的 RAM 用户，再把 AccessKey ID 与 Secret 添加到 Lumen。新账号默认使用私有权限，密钥只保存在这台 Mac 的钥匙串中。")
                Text("建议从只读或单 Bucket 读写权限开始，需要上传、删除或移动时再补充对应权限。不要使用主账号 AccessKey。")
            }
            helpSection("像访达一样浏览") {
                Text("单击选择，双击打开文件夹或预览文件。按住 Command 多选，Shift 连续选择；Return 重命名，空格快速查看，Command–1 / Command–2 切换网格与列表。")
            }
        case .transfers:
            helpSection("失败与重试") {
                Text("短暂断网、限流和服务端故障会自动重试。应用退出时仍在进行的任务会在下次打开后显示为“传输中断”，可以从传输列表重新开始；这不是字节级续传。")
                Text("若原文件或下载目录的访问权限已失效，Lumen 会保留历史并说明为何不能直接重试。")
            }
            helpSection("同名项目") {
                Text("上传遇到同名对象时会先询问覆盖或跳过；下载不会覆盖本地已有文件。上传完成后的“已校验”表示 OSS 返回的 CRC64 与本地内容一致。")
            }
        case .recovery:
            helpSection("撤销云端整理") {
                Text("重命名和移动成功后，可以立即按 Command–Z 撤销。撤销只在原账号与原 Bucket 中生效。")
            }
            helpSection("恢复删除") {
                Text("Bucket 开启版本控制时，OSS 会为删除操作返回 delete marker。Lumen 只在拿到精确 marker 版本后提供撤销；未开启版本控制时，删除是永久的。")
            }
            helpSection("账号配置恢复") {
                Text("Lumen 会为可读取的账号配置保留上一份备份。主配置损坏时会自动恢复并保留损坏文件；若备份也不可读，请复制诊断信息并通过支持入口反馈。诊断信息不包含账号标识或密钥。")
            }
        case .updates:
            helpSection("自动更新") {
                Text("Lumen 使用 Sparkle 检查 GitHub Releases。发现新版本后可以直接安装，安装完成会退出并重新打开应用。自动检查可在“设置 › 通用”关闭。")
                Link("查看发布记录", destination: AppLinks.releases)
            }
        case .shortcuts:
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                shortcut("Command–O", "上传图片")
                shortcut("Shift–Command–V", "从剪贴板上传")
                shortcut("Shift–Command–N", "新建文件夹")
                shortcut("Command–Z", "撤销上一步可恢复的云端操作")
                shortcut("Command–1 / Command–2", "网格 / 列表")
                shortcut("Command–[ / Command–]", "后退 / 前进")
                shortcut("Command–R", "刷新")
                shortcut("Space", "快速查看")
                shortcut("Return", "重命名")
            }
        case .privacyAndSupport:
            helpSection("隐私") {
                Text("AccessKey Secret 与 STS Token 存在 macOS 钥匙串；账号偏好和传输历史保存在本机。诊断摘要不会包含账号名、AccessKey ID、Bucket、对象键、本地路径、URL、请求 ID、Secret 或 Token。")
                Link("阅读隐私说明", destination: AppLinks.privacy)
            }
            helpSection("获得支持") {
                Link("支持与常见问题", destination: AppLinks.support)
                Link("问题与功能建议", destination: AppLinks.issues)
                Link("安全政策", destination: AppLinks.security)
                Link("私密报告安全问题", destination: AppLinks.privateSecurityReport)
                Link("Lumen 官网", destination: AppLinks.website)
            }
        }
    }

    private func helpSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
            Text(action)
                .foregroundStyle(.secondary)
        }
    }

    private func copyDiagnostics() {
        let report = DiagnosticsReport.make()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted
    case transfers
    case recovery
    case updates
    case shortcuts
    case privacyAndSupport

    var id: String { rawValue }
    var path: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: "开始使用"
        case .transfers: "传输与冲突"
        case .recovery: "撤销与恢复"
        case .updates: "软件更新"
        case .shortcuts: "键盘快捷键"
        case .privacyAndSupport: "隐私与支持"
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: "sparkles"
        case .transfers: "arrow.up.arrow.down"
        case .recovery: "arrow.uturn.backward.circle"
        case .updates: "arrow.triangle.2.circlepath"
        case .shortcuts: "command"
        case .privacyAndSupport: "lock.shield"
        }
    }
}

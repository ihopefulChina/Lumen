import AppKit
import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Lumen", id: "main") {
            WorkspaceRoot()
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            LumenCommands()
        }

        Settings {
            SettingsView()
                .environment(AppModel.settingsSession)
                .frame(width: 520, height: 560)
        }

        MenuBarExtra(isInserted: menuBarBinding) {
            TransferMenu()
                .environment(AppServices.shared.focused ?? AppModel.settingsSession)
        } label: {
            Label("Lumen", systemImage: "photo.on.rectangle.angled")
        }
    }
}

private struct WorkspaceRoot: View {
    @State private var model = AppModel()

    var body: some View {
        RootView()
            .environment(model)
            .background(WindowFocusProbe { model.becomeFocused() })
            .onAppear {
                do {
                    try SecretStore.migrateLegacySecrets()
                } catch {
                    model.present(error.localizedDescription, error: true)
                }
                model.bootstrap()
                model.becomeFocused()
            }
    }
}

final class LumenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppServices.shared.routeIncoming(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppServices.shared.transfers.activeCount > 0 else {
                return .terminateNow
            }
            let alert = NSAlert()
            alert.messageText = "还有文件在传输"
            alert.informativeText = "现在退出会中断未完成的上传或下载。"
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "继续传输")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}

struct LumenCommands: Commands {
    @FocusedValue(\.lumenActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("上传图片…") { actions?.upload() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("从剪贴板上传") { actions?.paste() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("添加账号…") { actions?.addAccount() }
                .keyboardShortcut("n", modifiers: [.command])
            Divider()
            Button("新建文件夹…") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Button("复制链接") { actions?.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("复制 Markdown") { actions?.copyMarkdown() }
            Button("复制 HTML") { actions?.copyHTML() }
            Divider()
            Button("全选") { actions?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command])
            Button("取消全选") { actions?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                AppServices.shared.updates.checkForUpdates()
            }
        }
        CommandGroup(replacing: .help) {
            Button("Lumen 帮助") {
                NSWorkspace.shared.open(AppLinks.github)
            }
            Button("在 GitHub 打开仓库") {
                NSWorkspace.shared.open(AppLinks.github)
            }
            Button("问题与反馈") {
                NSWorkspace.shared.open(AppLinks.issues)
            }
        }
        CommandMenu("浏览") {
            Button("后退") { actions?.goBack() }
                .keyboardShortcut("[", modifiers: [.command])
            Button("前进") { actions?.goForward() }
                .keyboardShortcut("]", modifiers: [.command])
            Divider()
            Button("刷新") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("快速查看") { actions?.quickLook() }
            Divider()
            Button("网格") { actions?.grid() }
                .keyboardShortcut("1", modifiers: [.command])
            Button("列表") { actions?.list() }
                .keyboardShortcut("2", modifiers: [.command])
        }
    }
}

struct LumenActions {
    var upload: () -> Void
    var paste: () -> Void
    var addAccount: () -> Void
    var newFolder: () -> Void
    var copyLink: () -> Void
    var copyMarkdown: () -> Void
    var copyHTML: () -> Void
    var refresh: () -> Void
    var quickLook: () -> Void
    var grid: () -> Void
    var list: () -> Void
    var goBack: () -> Void
    var goForward: () -> Void
    var selectAll: () -> Void
    var deselectAll: () -> Void
}

private struct LumenActionsKey: FocusedValueKey {
    typealias Value = LumenActions
}

extension FocusedValues {
    var lumenActions: LumenActions? {
        get { self[LumenActionsKey.self] }
        set { self[LumenActionsKey.self] = newValue }
    }
}

private var menuBarBinding: Binding<Bool> {
    Binding(
        get: { MainActor.assumeIsolated { AppServices.shared.showMenuBarExtra } },
        set: { value in
            MainActor.assumeIsolated { AppServices.shared.showMenuBarExtra = value }
        }
    )
}

@MainActor
enum WindowActions {
    static let workspaceID = NSUserInterfaceItemIdentifier("lumen.workspace")

    static func prepare(_ window: NSWindow) {
        window.identifier = workspaceID
        window.tabbingMode = .disallowed
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    static func notify(_ message: String, title: String = "Lumen") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private struct WindowFocusProbe: NSViewRepresentable {
    var onFocus: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onFocus = onFocus
    }

    final class Probe: NSView {
        var onFocus: (() -> Void)?

        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            WindowActions.prepare(window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(becameKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            if window.isKeyWindow {
                onFocus?()
            }
        }

        @objc private func becameKey() {
            onFocus?()
        }
    }
}

import AppKit
import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Lumen", id: "main") {
            RootView()
                .environment(model)
                .onAppear { model.bootstrap() }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            LumenCommands()
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520, height: 480)
        }

        MenuBarExtra(isInserted: $model.showMenuBarExtra) {
            TransferMenu()
                .environment(model)
        } label: {
            Label("Lumen", systemImage: "photo.on.rectangle.angled")
        }
    }
}

final class LumenAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.ingestIncoming(urls)
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
            guard AppModel.shared.transfers.activeCount > 0 else {
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

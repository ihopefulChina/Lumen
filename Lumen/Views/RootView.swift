import AppKit
import QuickLook
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFileImporter = false
    @State private var showFolderPrompt = false
    @State private var folderName = ""

    var body: some View {
        rootContent
            .frame(minWidth: 880, minHeight: 560)
            .modifier(RootPresentation(
                showFileImporter: $showFileImporter,
                showFolderPrompt: $showFolderPrompt,
                folderName: $folderName
            ))
            .focusedSceneValue(\.lumenActions, actions)
            .onAppear(perform: installKeyMonitor)
    }

    @ViewBuilder
    private var rootContent: some View {
        if model.accounts.isEmpty {
            WelcomeView()
        } else {
            WorkspaceView(
                showFileImporter: $showFileImporter,
                showFolderPrompt: $showFolderPrompt
            )
        }
    }

    private var actions: LumenActions {
        LumenActions(
            upload: { showFileImporter = true },
            paste: { model.pasteFromClipboard() },
            addAccount: { model.editingAccount = nil; model.showAccountSheet = true },
            newFolder: { showFolderPrompt = true },
            copyLink: { model.copyURLs(style: .plain) },
            copyMarkdown: { model.copyURLs(style: .markdown) },
            copyHTML: { model.copyURLs(style: .html) },
            refresh: { Task { await model.refreshListing() } },
            quickLook: { Task { await model.quickLookSelection() } },
            grid: { Motion.run(reduceMotion) { model.browser.viewMode = .grid } },
            list: { Motion.run(reduceMotion) { model.browser.viewMode = .list } },
            goBack: { model.goBack() },
            goForward: { model.goForward() }
        )
    }

    private func installKeyMonitor() {
        KeyMonitor.install { [model] event in
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 51, flags.isEmpty, !model.browser.selectedKeys.isEmpty {
                model.requestDeleteSelection()
                return nil
            }
            if event.keyCode == 49, flags.isEmpty, model.previewItem == nil {
                Task { await model.quickLookSelection() }
                return nil
            }
            return event
        }
    }
}

private enum KeyMonitor {
    nonisolated(unsafe) static var token: Any?

    static func install(_ handler: @escaping (NSEvent) -> NSEvent?) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }
}

private struct RootPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showFileImporter: Bool
    @Binding var showFolderPrompt: Bool
    @Binding var folderName: String

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.showAccountSheet) {
                AccountSheet(draft: AccountDraft.fresh())
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .json, .text, .plainText, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    model.upload(urls: urls)
                }
            }
            .onChange(of: model.wantsNewFolder) { _, wanted in
                if wanted {
                    showFolderPrompt = true
                    model.wantsNewFolder = false
                }
            }
            .alert("新建文件夹", isPresented: $showFolderPrompt) {
                TextField("名称", text: $folderName)
                Button("取消", role: .cancel) { folderName = "" }
                Button("创建") {
                    let name = folderName
                    folderName = ""
                    Task { await model.createFolder(named: name) }
                }
            } message: {
                Text("文件夹会出现在当前路径下。")
            }
            .confirmationDialog("删除所选对象？", isPresented: $model.wantsDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    Task { await model.deleteSelection() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对象会从存储空间中永久移除。")
            }
            .confirmationDialog(
                "上传 \(model.pendingOpenURLs.count) 个文件到当前文件夹？",
                isPresented: Binding(
                    get: { !model.pendingOpenURLs.isEmpty && model.hasWorkspace },
                    set: { if !$0 { model.cancelPendingOpen() } }
                ),
                titleVisibility: .visible
            ) {
                Button("上传") { model.confirmPendingOpen() }
                Button("取消", role: .cancel) { model.cancelPendingOpen() }
            } message: {
                Text("这些文件是从访达或程序坞打开的。")
            }
            .quickLookPreview($model.previewItem)
            .onChange(of: model.transfers.activeCount) { _, count in
                model.showMenuBarExtra = count > 0 && model.settings.showMenuBarWhileTransferring
            }
            .onChange(of: model.browser.selectedKeys) { _, _ in
                Task { await model.loadInspector() }
            }
    }
}

private struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showFileImporter: Bool
    @Binding var showFolderPrompt: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            BrowserView(showFileImporter: $showFileImporter)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 304, max: 380)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.transfers.hasJobs {
                TransferTray()
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: model.transfers.hasJobs)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("上传", systemImage: "square.and.arrow.up")
                }
                .help("上传图片到当前文件夹")

                Button {
                    showFolderPrompt = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }

                Picker("视图", selection: $model.browser.viewMode) {
                    ForEach(BrowserViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 88)
                .help("切换网格或列表")

                Button {
                    Motion.run(reduceMotion) { model.showInspector.toggle() }
                } label: {
                    Label("信息", systemImage: "sidebar.trailing")
                }
                .help("显示或隐藏检查器")
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) {
                    model.banner = nil
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(2.4))
                    if model.banner?.id == banner.id {
                        Motion.run(reduceMotion) { model.banner = nil }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: model.banner?.id)
    }
}

private struct BannerView: View {
    let banner: BannerMessage
    var dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 8) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .yellow : .green)
                Text(banner.text)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .lumenGlass(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }
}

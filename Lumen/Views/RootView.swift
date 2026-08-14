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
            rename: {
                guard !model.isOrganizingCloud else { return }
                model.browser.beginRenaming()
            },
            openSelection: { openFocusedItem(model) },
            refresh: { Task { await model.refreshListing() } },
            quickLook: { Task { await model.quickLookSelection() } },
            grid: { Motion.run(reduceMotion) { model.browser.viewMode = .grid } },
            list: { Motion.run(reduceMotion) { model.browser.viewMode = .list } },
            goBack: { model.goBack() },
            goForward: { model.goForward() },
            selectAll: { model.browser.selectAllVisible() },
            deselectAll: { model.browser.clearSelection() }
        )
    }

    private func installKeyMonitor() {
        KeyMonitor.install { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event
            }
            guard let model = AppServices.shared.focused else { return event }
            if event.keyCode == 51, flags.isEmpty, !model.browser.selectedKeys.isEmpty {
                model.requestDeleteSelection()
                return nil
            }
            if event.keyCode == 0, flags == .command {
                model.browser.selectAllVisible()
                return nil
            }
            if event.keyCode == 0, flags == [.command, .shift] {
                model.browser.clearSelection()
                return nil
            }
            if event.keyCode == 53, flags.isEmpty {
                if model.browser.renameSession != nil {
                    model.browser.cancelRenaming()
                    return nil
                }
                if !model.browser.selectedKeys.isEmpty {
                    model.browser.clearSelection()
                    return nil
                }
            }
            if event.keyCode == 125, flags == .command,
               !model.browser.selectedKeys.isEmpty {
                openFocusedItem(model)
                return nil
            }
            if [123, 124, 125, 126].contains(event.keyCode),
               flags.isEmpty || flags == .shift {
                let direction: BrowserSelectionDirection = [123, 126].contains(event.keyCode) ? .previous : .next
                model.browser.moveSelection(direction, extending: flags.contains(.shift))
                return nil
            }
            if event.keyCode == 36, flags.isEmpty {
                guard !model.isOrganizingCloud else { return event }
                if model.browser.beginRenaming() {
                    return nil
                }
            }
            if event.keyCode == 49, flags.isEmpty, model.previewItem == nil {
                Task { await model.quickLookSelection() }
                return nil
            }
            return event
        }
    }

    private func openFocusedItem(_ model: AppModel) {
        let key = model.browser.focusedKey
            ?? model.browser.orderedVisibleKeys.first(where: { model.browser.selectedKeys.contains($0) })
        guard let key else { return }
        if let folder = model.browser.folders.first(where: { $0.prefix == key }) {
            model.openFolder(folder)
        } else {
            Task { await model.quickLookSelection() }
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
                allowedContentTypes: ImageKind.importTypes,
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
            .confirmationDialog(model.deleteDialogTitle, isPresented: $model.wantsDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    Task { await model.deleteSelection() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(model.deleteDialogMessage)
            }
            .confirmationDialog(
                model.overwritePrompt?.title ?? "文件已存在",
                isPresented: Binding(
                    get: { model.overwritePrompt != nil },
                    set: { if !$0 { model.cancelOverwrite() } }
                ),
                titleVisibility: .visible
            ) {
                Button("覆盖") { model.confirmOverwrite() }
                Button("跳过这些文件") { model.skipOverwriteConflicts() }
                Button("取消", role: .cancel) { model.cancelOverwrite() }
            } message: {
                Text(model.overwritePrompt?.message ?? "")
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

                Button {
                    model.toggleCurrentFolderFavorite()
                } label: {
                    Label(
                        model.isCurrentFolderFavorite ? "从常用中移除" : "添加到常用",
                        systemImage: model.isCurrentFolderFavorite ? "star.fill" : "star"
                    )
                }
                .disabled(model.selectedBucket == nil)
                .help(model.isCurrentFolderFavorite ? "从常用位置移除" : "添加当前文件夹到常用位置")

                Menu {
                    Picker("排序依据", selection: $model.browser.sortField) {
                        ForEach(BrowserSortField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    Divider()
                    Picker("顺序", selection: $model.browser.sortDirection) {
                        ForEach(BrowserSortDirection.allCases) { direction in
                            Label(direction.title, systemImage: direction.symbol).tag(direction)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .help("排序项目")

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

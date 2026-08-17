import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

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
            undoTitle: model.browser.renameSession == nil
                ? model.undoCloudOperationTitle
                : "撤销编辑",
            canUndo: model.browser.renameSession != nil || model.canUndoCloudOperation,
            undo: {
                switch WorkspaceUndo.resolve(
                    isRenaming: model.browser.renameSession != nil,
                    fieldCanUndo: NSApp.keyWindow?.firstResponder?.undoManager?.canUndo == true
                ) {
                case .field:
                    NSApp.keyWindow?.firstResponder?.undoManager?.undo()
                case .cancelRename:
                    model.browser.cancelRenaming()
                case .cloud:
                    Task { await model.undoLastCloudOperation() }
                }
            },
            upload: { showFileImporter = true },
            copy: { model.copyCloudSelection() },
            canCopy: model.canCopyCloudItems,
            cut: { model.cutCloudSelection() },
            paste: { model.paste() },
            canPaste: model.canPaste,
            pasteLocalFiles: { model.pasteFromClipboard() },
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
            canShowInformation: model.canShowInformation,
            showInformation: { model.showInspector = true },
            canActOnObject: model.browser.primarySelection != nil && model.browser.selectedObjects.count == 1,
            showObjectProperties: {
                if let object = model.browser.primarySelection { model.presentObjectProperties(for: object) }
            },
            grid: { Motion.run(reduceMotion) { model.setPreferredViewMode(.grid) } },
            list: { Motion.run(reduceMotion) { model.setPreferredViewMode(.list) } },
            goBack: { model.goBack() },
            goForward: { model.goForward() },
            selectAll: { model.browser.selectAllVisible() },
            deselectAll: { model.browser.clearSelection() }
        )
    }

    private func installKeyMonitor() {
        KeyMonitor.install { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard let model = AppServices.shared.focused ?? AppServices.shared.sessions.first else {
                return event
            }
            let editingText = BrowserKeyEvent.isEditingText
            if BrowserKeyEvent.isPaste(event, flags: flags) {
                // While editing text (rename field, dialogs), ⌘V must paste text,
                // never cloud items.
                if !editingText, model.canPasteCloudItems || model.canPaste {
                    DispatchQueue.main.async { model.paste() }
                    return nil
                }
                return event
            }
            // All shortcuts below act on the browser. Do not hijack key events
            // while a text field is being edited, a sheet/dialog is open, or a
            // different window (help / transfers / settings) is key.
            let keyWindow = NSApp.keyWindow
            let isWorkspaceWindow = keyWindow?.identifier == WindowActions.workspaceID
            guard !editingText, isWorkspaceWindow, keyWindow?.attachedSheet == nil else {
                return event
            }
            if event.keyCode == 51, flags.isEmpty, !model.browser.selectedKeys.isEmpty {
                guard !model.isOrganizingCloud else { return event }
                model.requestDeleteSelection()
                return nil
            }
            if event.keyCode == 0, flags == .command {
                model.browser.selectAllVisible()
                return nil
            }
            if BrowserKeyEvent.isCut(event, flags: flags) {
                guard model.canCopyCloudItems else { return event }
                model.cutCloudSelection()
                return nil
            }
            if BrowserKeyEvent.isCopy(event, flags: flags) {
                guard model.canCopyCloudItems else { return event }
                model.copyCloudSelection()
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

enum WorkspaceUndo {
    enum Action: Equatable {
        case field
        case cancelRename
        case cloud
    }

    static func resolve(isRenaming: Bool, fieldCanUndo: Bool) -> Action {
        if isRenaming {
            return fieldCanUndo ? .field : .cancelRename
        }
        return .cloud
    }
}

enum BrowserKeyEvent {
    static var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    static func isPaste(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        isCommandCharacter("v", keyCode: 9, event: event, flags: flags)
    }

    static func isCopy(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        isCommandCharacter("c", keyCode: 8, event: event, flags: flags)
    }

    static func isCut(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        isCommandCharacter("x", keyCode: 7, event: event, flags: flags)
    }

    static func isCommandCharacter(
        _ character: String,
        keyCode: UInt16,
        event: NSEvent,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard flags == .command else { return false }
        return event.keyCode == keyCode || event.charactersIgnoringModifiers?.lowercased() == character
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

    /// 上传不限制文件类型（OSS 支持任意文件）。
    private static let uploadPickerTypes: [UTType] = [.item, .folder]

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.showAccountSheet) {
                AccountSheet(draft: initialAccountDraft)
            }
            .sheet(isPresented: $model.showInspector) {
                InspectorView()
            }
            .sheet(isPresented: $model.showObjectProperties) {
                if let properties = model.objectPropertiesModel {
                    ObjectPropertiesView(properties: properties)
                }
            }
            .sheet(isPresented: $model.showCrossBucketPreflight) {
                if let preflight = model.crossBucketPreflight {
                    CrossBucketPreflightView(
                        preflight: preflight,
                        confirm: model.confirmCrossBucketOperation
                    )
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.uploadPickerTypes,
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
                Button("取消", role: .cancel) {
                    model.cancelPendingDelete()
                }
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
                guard model.showInspector else { return }
                Task { await model.loadInspector() }
            }
            .onChange(of: model.showInspector) { _, isPresented in
                guard isPresented else { return }
                Task { await model.loadInspector() }
            }
    }

    private var initialAccountDraft: AccountDraft {
        #if DEBUG
        if ScreenshotDemo.currentMode == .account {
            return ScreenshotDemo.accountDraft
        }
        #endif
        return AccountDraft.fresh()
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
                .help("上传任意类型文件到当前文件夹")

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

                Picker("视图", selection: Binding(
                    get: { model.browser.viewMode },
                    set: { mode in
                        Motion.run(reduceMotion) { model.setPreferredViewMode(mode) }
                    }
                )) {
                    ForEach(BrowserViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 88)
                .help("切换网格或列表")

                Button {
                    model.showInspector = true
                } label: {
                    Label("显示信息", systemImage: "info.circle")
                }
                .disabled(!model.canShowInformation)
                .help("显示当前文件夹或所选项目的信息（⌘I）")
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(
                    banner: banner,
                    dismiss: { model.banner = nil },
                    perform: { action in
                        model.banner = nil
                        switch action {
                        case .undoCloudOperation:
                            Task { await model.undoLastCloudOperation() }
                        }
                    }
                )
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: banner.displayDuration)
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
    var perform: (BannerAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .yellow : .green)
            Text(banner.text)
                .font(.callout.weight(.medium))

            if let action = banner.action {
                Divider()
                    .frame(height: 14)
                Button("撤销") {
                    perform(action)
                }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
                .accessibilityHint("恢复上一次可撤销的云端操作")
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
            .help("关闭提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .padding(.vertical, 8)
        .lumenGlass(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }
}

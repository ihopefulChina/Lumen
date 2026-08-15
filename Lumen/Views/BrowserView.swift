import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Binding var showFileImporter: Bool
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var model = model
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .searchable(text: $model.browser.searchText, placement: .toolbar, prompt: searchPrompt)
            .searchScopes($model.searchScope) {
                ForEach(BucketSearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        model.goBack()
                    } label: {
                        Label("后退", systemImage: "chevron.left")
                    }
                    .disabled(!model.browser.canGoBack)
                    .help("后退")

                    Button {
                        model.goForward()
                    } label: {
                        Label("前进", systemImage: "chevron.right")
                    }
                    .disabled(!model.browser.canGoForward)
                    .help("前进")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.selectedBucket != nil {
                    PathBar(showFileImporter: $showFileImporter)
                }
            }
            .overlay {
                if let prefix = model.browser.activeDropPrefix, prefix == model.browser.prefix {
                    dropScrim(title: "放到当前文件夹")
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.upload(urls: urls, to: model.browser.prefix, applyTemplate: false)
                return true
            } isTargeted: { targeted in
                model.browser.setDropTarget(model.browser.prefix, active: targeted)
            }
            .dropDestination(for: CloudDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                model.moveCloudItems(payload, to: model.browser.prefix)
                return true
            } isTargeted: { targeted in
                model.browser.setDropTarget(model.browser.prefix, active: targeted)
            }
            .onPasteCommand(of: [.image, .fileURL, .gif, .webP, .png, .jpeg]) { _ in
                model.pasteFromClipboard()
            }
            .onChange(of: photos) { _, items in
                Task { await importPhotos(items) }
            }
            .task(id: searchRequest) {
                guard isBucketSearchPresented else {
                    model.searchController.clear()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    try Task.checkCancellation()
                    await model.runBucketSearch()
                } catch {
                    model.cancelBucketSearch()
                }
            }
            .overlay(alignment: .top) {
                if model.isOrganizingCloud {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在整理云端项目…")
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.bar, in: Capsule())
                    .padding(.top, 8)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedBucket == nil {
            ContentUnavailableView("选择一个存储空间", systemImage: "externaldrive", description: Text("从左侧打开 Bucket，就可以浏览和上传素材。"))
        } else if isBucketSearchPresented {
            BucketSearchView()
        } else if model.browser.isLoading && model.browser.objects.isEmpty && model.browser.folders.isEmpty {
            ProgressView("正在读取对象…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.browser.errorMessage, model.browser.objects.isEmpty && model.browser.folders.isEmpty {
            ContentUnavailableView {
                Label("无法读取", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("再试一次") { Task { await model.refreshListing() } }
            }
        } else if model.browser.visibleFolders.isEmpty && model.browser.visibleObjects.isEmpty {
            emptyState
        } else if model.browser.viewMode == .grid {
            grid
        } else {
            table
        }
    }

    private var title: String {
        if isBucketSearchPresented {
            return model.selectedBucket?.name ?? "搜索"
        }
        if model.browser.prefix.isEmpty {
            return model.selectedBucket?.name ?? "素材"
        }
        return PathTemplate.lastComponent(model.browser.prefix)
    }

    private var subtitle: String {
        if isBucketSearchPresented {
            let progress = model.searchController.progress
            return model.searchController.isSearching
                ? "正在搜索当前 Bucket"
                : "找到 \(progress.matched) 项"
        }
        let folders = model.browser.visibleFolders.count
        let files = model.browser.visibleObjects.count
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) 个文件夹") }
        if files > 0 { parts.append("\(files) 项") }
        return parts.joined(separator: " · ")
    }

    private var searchPrompt: String {
        model.searchScope == .folder ? "搜索当前文件夹" : "搜索当前 Bucket"
    }

    private var isBucketSearchPresented: Bool {
        guard model.searchScope == .bucket else { return false }
        let text = model.browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty || model.searchFilter != .all
    }

    private var searchRequest: BucketSearchRequest {
        BucketSearchRequest(
            accountID: model.selectedAccountID,
            bucketName: model.selectedBucketName,
            text: model.browser.searchText,
            scope: model.searchScope,
            filter: model.searchFilter
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(model.browser.searchText.isEmpty ? "此文件夹为空" : "没有匹配的项目")
                .font(.title3)
            if model.browser.searchText.isEmpty {
                Text("拖入文件，或从工具栏上传。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("选取文件…") { showFileImporter = true }
                    PhotosPicker(selection: $photos, maxSelectionCount: 80, matching: .images) {
                        Text("从照片选取")
                    }
                }
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu { backgroundMenu() }
    }

    private var grid: some View {
        let selected = model.browser.selectedKeys
        let _ = model.browser.selectionEpoch
        return GeometryReader { geo in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)], spacing: 12) {
                    ForEach(model.browser.visibleFolders) { folder in
                        FolderCell(
                            folder: folder,
                            selected: selected.contains(folder.prefix),
                            dropTargeted: model.browser.activeDropPrefix == folder.prefix,
                            renameSession: renameSession(for: folder.prefix),
                            renameText: renameTextBinding,
                            onRenameCommit: commitRename,
                            onRenameCancel: model.browser.cancelRenaming
                        ) {
                            selectFolder(folder, modifiers: currentSelectionModifiers)
                        } onOpen: {
                            model.openFolder(folder)
                        }
                        .contextMenu {
                            Button("打开") {
                                model.openFolder(folder)
                            }
                            .onAppear { selectForMenu(folder.prefix) }
                            folderMenu(folder)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            model.upload(urls: urls, to: folder.prefix, applyTemplate: false)
                            return true
                        } isTargeted: { targeted in
                            model.browser.setDropTarget(folder.prefix, active: targeted)
                        }
                        .dropDestination(for: CloudDragPayload.self) { payloads, _ in
                            guard let payload = payloads.first else { return false }
                            model.moveCloudItems(payload, to: folder.prefix)
                            return true
                        } isTargeted: { targeted in
                            model.browser.setDropTarget(folder.prefix, active: targeted)
                        }
                        .onDrag {
                            model.finderItemProvider(clickedKey: folder.prefix)
                        } preview: {
                            dragPreview(name: folder.name, symbol: "folder.fill")
                        }
                    }
                    ForEach(model.browser.visibleObjects) { object in
                        AssetCell(
                            object: object,
                            selected: selected.contains(object.key),
                            renameSession: renameSession(for: object.key),
                            renameText: renameTextBinding,
                            onRenameCommit: commitRename,
                            onRenameCancel: model.browser.cancelRenaming
                        ) {
                            select(object, modifiers: currentSelectionModifiers)
                        } onOpen: {
                            Task { await model.quickLookSelection() }
                        }
                        .contextMenu {
                            Button("快速查看") {
                                selectForMenu(object.key)
                                Task { await model.quickLookSelection() }
                            }
                            .onAppear { selectForMenu(object.key) }
                            objectMenu(object)
                        }
                        .onDrag {
                            model.finderItemProvider(clickedKey: object.key)
                        } preview: {
                            dragPreview(name: object.name, symbol: object.isImage ? "photo" : "doc")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
            .background {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu { backgroundMenu() }
            }
        }
        .onTapGesture {
            model.browser.clearSelection()
        }
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var table: some View {
        Table(of: BrowserRow.self, selection: tableSelection) {
            TableColumn("名称") { row in
                HStack(spacing: 6) {
                    if row.isFolder {
                        FinderFolderIcon(size: 16)
                    } else if let object = row.object, object.isImage {
                        ThumbnailView(object: object, style: .row)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else if let object = row.object {
                        FinderFileIcon(key: object.key, size: 16)
                    } else {
                        Image(systemName: row.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    if let renameSession = renameSession(for: row.id) {
                        FinderRenameField(
                            text: renameTextBinding,
                            initialSelection: renameSession.initialSelection,
                            alignment: .left,
                            isCommitting: renameSession.isCommitting,
                            onCommit: commitRename,
                            onCancel: model.browser.cancelRenaming
                        )
                        .frame(maxWidth: .infinity, minHeight: 20)
                    } else {
                        Text(row.name)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrag {
                    model.finderItemProvider(clickedKey: row.id)
                } preview: {
                    dragPreview(name: row.name, symbol: row.symbol)
                }
                .onTapGesture(count: 2) {
                    if let folder = row.folder {
                        model.openFolder(folder)
                    } else {
                        Task { await model.quickLookSelection() }
                    }
                }
                .background {
                    if let folder = row.folder {
                        Color.clear
                            .dropDestination(for: URL.self) { urls, _ in
                                model.upload(urls: urls, to: folder.prefix, applyTemplate: false)
                                return true
                            } isTargeted: { targeted in
                                model.browser.setDropTarget(folder.prefix, active: targeted)
                            }
                            .dropDestination(for: CloudDragPayload.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                model.moveCloudItems(payload, to: folder.prefix)
                                return true
                            } isTargeted: { targeted in
                                model.browser.setDropTarget(folder.prefix, active: targeted)
                            }
                    }
                }
            }
            TableColumn("大小") { row in
                Text(row.sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)
            TableColumn("种类") { row in
                Text(row.kind)
                    .foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("修改时间") { row in
                Text(row.date)
                    .foregroundStyle(.secondary)
            }
            .width(160)
        } rows: {
            ForEach(tableRows) { row in
                TableRow(row)
                    .contextMenu {
                        if let object = row.object {
                            Button("快速查看") {
                                selectForMenu(object.key)
                                Task { await model.quickLookSelection() }
                            }
                            .onAppear { selectForMenu(object.key) }
                            objectMenu(object)
                        } else if let folder = row.folder {
                            Button("打开") { model.openFolder(folder) }
                                .onAppear { selectForMenu(folder.prefix) }
                            folderMenu(folder)
                        }
                    }
            }
        }
        .contextMenu { backgroundMenu() }
    }

    private var tableRows: [BrowserRow] {
        model.browser.visibleFolders.map(BrowserRow.init) + model.browser.visibleObjects.map(BrowserRow.init)
    }

    private var tableSelection: Binding<Set<BrowserRow.ID>> {
        Binding(
            get: { model.browser.selectedKeys },
            set: { model.browser.replaceSelection($0) }
        )
    }

    private func dropScrim(title: String) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar, in: Capsule())
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func backgroundMenu() -> some View {
        if model.cloudClipboard != nil {
            Button("粘贴到此处") { model.pasteCloudItems() }
            Divider()
        }
        Button("上传…") { showFileImporter = true }
        Button("从剪贴板上传") { model.pasteFromClipboard() }
        Button("新建文件夹…") { model.wantsNewFolder = true }
        Divider()
        Button("下载当前文件夹…") { model.downloadCurrentPrefix() }
        Button("刷新") { Task { await model.refreshListing() } }
        Divider()
        Button("全选") { model.browser.selectAllVisible() }
        if !model.browser.selectedKeys.isEmpty {
            Button("取消选择") { model.browser.clearSelection() }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: OSSFolder) -> some View {
        Button(model.isFavorite(prefix: folder.prefix) ? "从常用中移除" : "添加到常用") {
            model.toggleFavorite(prefix: folder.prefix, name: folder.name)
        }
        Divider()
        Button(downloadTitle(clickedKey: folder.prefix)) {
            selectForMenu(folder.prefix)
            model.downloadSelection()
        }
        Button("复制") {
            selectForMenu(folder.prefix)
            model.copyCloudSelection(clickedKey: folder.prefix)
        }
        Button("重命名…") {
            beginRenaming(key: folder.prefix)
        }
        .disabled(model.isOrganizingCloud)
        Divider()
        Button(deleteTitle(clickedKey: folder.prefix), role: .destructive) {
            selectForMenu(folder.prefix)
            model.requestDeleteSelection()
        }
    }

    @ViewBuilder
    private func objectMenu(_ object: OSSObject) -> some View {
        Button("复制链接") {
            selectForMenu(object.key)
            model.copyURLs(style: .plain)
        }
        Button("复制 Markdown") {
            selectForMenu(object.key)
            model.copyURLs(style: .markdown)
        }
        Divider()
        Button("复制") {
            selectForMenu(object.key)
            model.copyCloudSelection(clickedKey: object.key)
        }
        Button(downloadTitle(clickedKey: object.key)) {
            selectForMenu(object.key)
            model.downloadSelection()
        }
        Button("重命名…") {
            beginRenaming(key: object.key)
        }
        .disabled(model.isOrganizingCloud)
        Button("版本历史…") {
            selectForMenu(object.key)
            model.presentVersionHistory(for: object)
        }
        Divider()
        Button(deleteTitle(clickedKey: object.key), role: .destructive) {
            selectForMenu(object.key)
            model.requestDeleteSelection()
        }
    }

    private func selectForMenu(_ key: String) {
        if !model.browser.selectedKeys.contains(key) {
            model.browser.select(key: key, modifiers: [])
        }
    }

    private func downloadTitle(clickedKey: String) -> String {
        let keys: Set<String> = model.browser.selectedKeys.contains(clickedKey)
            ? model.browser.selectedKeys
            : [clickedKey]
        let files = model.browser.objects.filter { keys.contains($0.key) }.count
        let folders = model.browser.folders.filter { keys.contains($0.prefix) }.count
        if folders == 1 && files == 0 && keys.count == 1 {
            return "下载文件夹…"
        }
        if files + folders > 1 {
            return "下载 \(files + folders) 项…"
        }
        return "下载…"
    }

    private func deleteTitle(clickedKey: String) -> String {
        let keys: Set<String> = model.browser.selectedKeys.contains(clickedKey)
            ? model.browser.selectedKeys
            : [clickedKey]
        let count = keys.count
        if count > 1 {
            return "删除 \(count) 项…"
        }
        if model.browser.folders.contains(where: { $0.prefix == clickedKey }) {
            return "删除文件夹…"
        }
        return "删除…"
    }

    private var currentSelectionModifiers: BrowserSelectionModifiers {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: BrowserSelectionModifiers = []
        if flags.contains(.command) { modifiers.insert(.toggle) }
        if flags.contains(.shift) { modifiers.insert(.extendRange) }
        return modifiers
    }

    private func selectFolder(_ folder: OSSFolder, modifiers: BrowserSelectionModifiers) {
        model.browser.select(key: folder.prefix, modifiers: modifiers)
    }

    private func select(_ object: OSSObject, modifiers: BrowserSelectionModifiers) {
        model.browser.select(key: object.key, modifiers: modifiers)
    }

    private var renameTextBinding: Binding<String> {
        Binding(
            get: { model.browser.renameSession?.draft ?? "" },
            set: { model.browser.updateRenameDraft($0) }
        )
    }

    private func renameSession(for key: String) -> BrowserRenameSession? {
        guard model.browser.renameSession?.key == key else { return nil }
        return model.browser.renameSession
    }

    private func beginRenaming(key: String) {
        guard !model.isOrganizingCloud else { return }
        Task { @MainActor in
            await Task.yield()
            model.browser.beginRenaming(key: key)
        }
    }

    private func commitRename() {
        guard let session = model.browser.renameSession,
              !session.isCommitting
        else { return }
        model.browser.setRenameCommitting(true)
        Task { @MainActor in
            let succeeded: Bool
            switch session.kind {
            case .object:
                guard let object = model.browser.objects.first(where: { $0.key == session.key }) else {
                    model.browser.finishRenaming()
                    return
                }
                succeeded = await model.rename(object, to: session.draft)
            case .folder:
                guard let folder = model.browser.folders.first(where: { $0.prefix == session.key }) else {
                    model.browser.finishRenaming()
                    return
                }
                succeeded = await model.renameFolder(folder, to: session.draft)
            }
            if succeeded {
                model.browser.finishRenaming()
            } else {
                model.browser.setRenameCommitting(false)
            }
        }
    }

    private func dragPreview(name: String, symbol: String) -> some View {
        Label(name, systemImage: symbol)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var urls: [URL] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory.appending(path: "photo-\(UUID().uuidString).\(ext)")
                try? data.write(to: url)
                urls.append(url)
            }
        }
        photos = []
        if !urls.isEmpty {
            model.upload(urls: urls, ownedTemporaryURLs: Set(urls))
        }
    }
}

private struct BucketSearchRequest: Hashable {
    var accountID: UUID?
    var bucketName: String?
    var text: String
    var scope: BucketSearchScope
    var filter: BucketSearchFilter
}

private struct PathBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showFileImporter: Bool

    var body: some View {
        let crumbs = model.selectedBucket.map { PathTemplate.crumbs(bucket: $0.name, prefix: model.browser.prefix) } ?? []
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            if crumb.prefix != model.browser.prefix {
                                model.goToPrefix(crumb.prefix)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: "externaldrive")
                                        .font(.caption)
                                } else {
                                    Image(nsImage: SystemIcons.folderSmall)
                                        .resizable()
                                        .frame(width: 13, height: 13)
                                }
                                Text(crumb.title)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                        .background {
                            if model.browser.activeDropPrefix == crumb.prefix, crumb.prefix != model.browser.prefix {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                            }
                        }
                        .contextMenu {
                            pathMenu(prefix: crumb.prefix, isCurrent: crumb.prefix == model.browser.prefix)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            model.upload(urls: urls, to: crumb.prefix, applyTemplate: false)
                            return true
                        } isTargeted: { targeted in
                            model.browser.setDropTarget(crumb.prefix, active: targeted)
                        }
                        .dropDestination(for: CloudDragPayload.self) { payloads, _ in
                            guard let payload = payloads.first else { return false }
                            model.moveCloudItems(payload, to: crumb.prefix)
                            return true
                        } isTargeted: { targeted in
                            model.browser.setDropTarget(crumb.prefix, active: targeted)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.browser.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .help("正在刷新")
            } else {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .contextMenu {
            pathMenu(prefix: model.browser.prefix, isCurrent: true)
        }
    }

    private var statusText: String {
        if model.searchScope == .bucket,
           (!model.browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.searchFilter != .all) {
            let progress = model.searchController.progress
            return model.searchController.isSearching
                ? "已扫描 \(progress.scanned) 项"
                : "找到 \(progress.matched) 项"
        }
        let selected = model.browser.selectedKeys.count
        if selected > 0 { return "已选 \(selected) 项" }
        let visible = model.browser.visibleFolders.count + model.browser.visibleObjects.count
        let query = model.browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "\(visible) 项" : "找到 \(visible) 项"
    }

    @ViewBuilder
    private func pathMenu(prefix: String, isCurrent: Bool) -> some View {
        if model.cloudClipboard != nil {
            Button("粘贴到此处") {
                guard let payload = model.cloudClipboard else { return }
                Task { await model.organizeCloud(payload, to: prefix, mode: .copy) }
            }
            Divider()
        }
        Button("复制路径") {
            model.copyFolderPath(prefix, includeBucket: false)
        }
        Button("复制完整路径") {
            model.copyFolderPath(prefix, includeBucket: true)
        }
        Button("复制链接") {
            model.copyFolderURL(prefix)
        }
        Divider()
        if !isCurrent {
            Button("转到此处") {
                model.goToPrefix(prefix)
            }
        }
        Button("上传到此处…") {
            if !isCurrent {
                model.goToPrefix(prefix)
            }
            showFileImporter = true
        }
        Button("在此处新建文件夹…") {
            if !isCurrent {
                model.goToPrefix(prefix)
            }
            model.wantsNewFolder = true
        }
        Button("下载此文件夹…") {
            if isCurrent {
                model.downloadCurrentPrefix()
            } else {
                model.downloadFolder(OSSFolder(prefix: prefix))
            }
        }
    }
}

private struct FolderCell: View {
    let folder: OSSFolder
    var selected: Bool
    var dropTargeted: Bool
    var renameSession: BrowserRenameSession?
    @Binding var renameText: String
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void
    var action: () -> Void
    var onOpen: () -> Void
    @State private var selectedDuringPress = false

    var body: some View {
        let highlighted = selected || dropTargeted
        ZStack(alignment: .bottom) {
            Button(action: selectOnRelease) {
                VStack(spacing: 4) {
                    FinderFolderIcon(size: 64)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(highlighted ? Color.accentColor.opacity(dropTargeted ? 0.4 : 0.3) : Color.clear)
                        }
                        .overlay {
                            if dropTargeted {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }

                    Text(folder.name)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(highlighted ? Color.accentColor : Color.clear)
                        }
                        .foregroundStyle(highlighted ? Color.white : Color.primary)
                        .opacity(renameSession == nil ? 1 : 0)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(FinderItemButtonStyle(onPress: selectOnPress))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))

            if let renameSession {
                FinderRenameField(
                    text: $renameText,
                    initialSelection: renameSession.initialSelection,
                    alignment: .center,
                    isCommitting: renameSession.isCommitting,
                    onCommit: onRenameCommit,
                    onCancel: onRenameCancel
                )
                .frame(height: 20)
                .padding(.horizontal, 3)
            }
        }
        .help(folder.name)
        .accessibilityLabel("文件夹，\(folder.name)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("双击打开")
    }

    private func selectOnPress() {
        selectedDuringPress = true
        action()
    }

    private func selectOnRelease() {
        if !selectedDuringPress { action() }
        selectedDuringPress = false
    }
}

private struct AssetCell: View {
    let object: OSSObject
    var selected: Bool
    var renameSession: BrowserRenameSession?
    @Binding var renameText: String
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void
    var action: () -> Void
    var onOpen: () -> Void
    @State private var selectedDuringPress = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: selectOnRelease) {
                VStack(spacing: 4) {
                    ThumbnailView(object: object)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                        }
                        .clipped()
                    Text(object.name)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .opacity(renameSession == nil ? 1 : 0)
                }
            }
            .buttonStyle(FinderItemButtonStyle(onPress: selectOnPress))
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })

            if let renameSession {
                FinderRenameField(
                    text: $renameText,
                    initialSelection: renameSession.initialSelection,
                    alignment: .center,
                    isCommitting: renameSession.isCommitting,
                    onCommit: onRenameCommit,
                    onCancel: onRenameCancel
                )
                .frame(height: 20)
                .padding(.horizontal, 3)
            }
        }
        .help(object.name)
        .accessibilityLabel("\(ImageKind.displayKind(for: object.key))，\(object.name)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("双击快速查看")
    }

    private func selectOnPress() {
        selectedDuringPress = true
        action()
    }

    private func selectOnRelease() {
        if !selectedDuringPress { action() }
        selectedDuringPress = false
    }
}

private struct FinderItemButtonStyle: ButtonStyle {
    var onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { onPress() }
            }
    }
}

private struct BrowserRow: Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var sizeLabel: String
    var kind: String
    var date: String
    var isFolder: Bool
    var object: OSSObject?
    var folder: OSSFolder?

    init(_ folder: OSSFolder) {
        self.id = folder.prefix
        self.name = folder.name
        self.symbol = "folder.fill"
        self.sizeLabel = "—"
        self.kind = "文件夹"
        self.date = "—"
        self.isFolder = true
        self.folder = folder
    }

    init(_ object: OSSObject) {
        self.id = object.key
        self.name = object.name
        self.symbol = object.isImage ? "photo" : "doc"
        self.sizeLabel = Formatters.bytes(object.size)
        self.kind = ImageKind.displayKind(for: object.key)
        self.date = Formatters.date(object.lastModified)
        self.isFolder = false
        self.object = object
    }
}

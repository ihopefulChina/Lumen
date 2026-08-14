import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Binding var showFileImporter: Bool
    @State private var photos: [PhotosPickerItem] = []
    @State private var renameTarget: OSSObject?
    @State private var renameText = ""
    @State private var folderToDelete: OSSFolder?

    var body: some View {
        @Bindable var model = model
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .searchable(text: $model.browser.searchText, placement: .toolbar, prompt: "搜索")
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
                if model.browser.isDropTargeted {
                    dropScrim
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.upload(urls: urls)
                return true
            } isTargeted: { targeted in
                model.browser.isDropTargeted = targeted
            }
            .onPasteCommand(of: [.image, .fileURL]) { _ in
                model.pasteFromClipboard()
            }
            .onChange(of: photos) { _, items in
                Task { await importPhotos(items) }
            }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("存储") {
                    if let renameTarget {
                        Task { await model.rename(renameTarget, to: renameText) }
                    }
                    renameTarget = nil
                }
            }
            .confirmationDialog(
                "删除文件夹“\(folderToDelete?.name ?? "")”？",
                isPresented: Binding(
                    get: { folderToDelete != nil },
                    set: { if !$0 { folderToDelete = nil } }
                )
            ) {
                Button("删除全部内容", role: .destructive) {
                    if let folderToDelete {
                        Task { await model.deleteFolder(folderToDelete) }
                    }
                    folderToDelete = nil
                }
                Button("取消", role: .cancel) { folderToDelete = nil }
            } message: {
                Text("文件夹里的对象会一并从 OSS 删除。")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedBucket == nil {
            ContentUnavailableView("选择一个存储空间", systemImage: "externaldrive", description: Text("从左侧打开 Bucket，就可以浏览和上传素材。"))
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
        if model.browser.prefix.isEmpty {
            return model.selectedBucket?.name ?? "素材"
        }
        return PathTemplate.lastComponent(model.browser.prefix)
    }

    private var subtitle: String {
        let folders = model.browser.visibleFolders.count
        let files = model.browser.visibleObjects.count
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) 个文件夹") }
        if files > 0 { parts.append("\(files) 项") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(model.browser.searchText.isEmpty ? "将图片、JSON 或文本拖到这里" : "没有匹配的项目")
                .font(.title3)
            if model.browser.searchText.isEmpty {
                Text("也可以从照片或访达选取。")
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
    }

    private var grid: some View {
        let selected = model.browser.selectedKeys
        let _ = model.browser.selectionEpoch
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)], spacing: 12) {
                ForEach(model.browser.visibleFolders) { folder in
                    FolderCell(
                        folder: folder,
                        selected: selected.contains(folder.prefix)
                    ) {
                        selectFolder(folder, additive: NSEvent.modifierFlags.contains(.command))
                    } onOpen: {
                        model.openFolder(folder)
                    }
                    .contextMenu {
                        Button("打开") { model.openFolder(folder) }
                        Button("删除…", role: .destructive) { folderToDelete = folder }
                    }
                }
                ForEach(model.browser.visibleObjects) { object in
                    AssetCell(
                        object: object,
                        selected: selected.contains(object.key)
                    ) {
                        select(object, additive: NSEvent.modifierFlags.contains(.command))
                    } onOpen: {
                        Task { await model.quickLookSelection() }
                    }
                    .contextMenu { objectMenu(object) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
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
                    } else if let object = row.object, !object.isImage {
                        FinderFileIcon(key: object.key, size: 16)
                    } else {
                        Image(systemName: row.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    Text(row.name)
                        .lineLimit(1)
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
                            objectMenu(object)
                        } else if let folder = row.folder {
                            Button("打开") { model.openFolder(folder) }
                            Button("删除…", role: .destructive) { folderToDelete = folder }
                        }
                    }
            }
        }
        .onTapGesture(count: 2) {
            if let key = model.browser.selectedKeys.first,
               let folder = model.browser.folders.first(where: { $0.prefix == key }) {
                model.openFolder(folder)
            } else {
                Task { await model.quickLookSelection() }
            }
        }
        .contextMenu {
            if let object = model.browser.primarySelection {
                objectMenu(object)
            }
        }
    }

    private var tableRows: [BrowserRow] {
        model.browser.visibleFolders.map(BrowserRow.init) + model.browser.visibleObjects.map(BrowserRow.init)
    }

    private var tableSelection: Binding<Set<BrowserRow.ID>> {
        Binding(
            get: { model.browser.selectedKeys },
            set: { model.browser.selectedKeys = $0 }
        )
    }

    private var dropScrim: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                Text("放到当前文件夹")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar, in: Capsule())
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func objectMenu(_ object: OSSObject) -> some View {
        Button("快速查看") {
            model.browser.selectedKeys = [object.key]
            Task { await model.quickLookSelection() }
        }
        Button("复制链接") {
            model.browser.selectedKeys = [object.key]
            model.copyURLs(style: .plain)
        }
        Button("复制 Markdown") {
            model.browser.selectedKeys = [object.key]
            model.copyURLs(style: .markdown)
        }
        Divider()
        Button("下载…") {
            model.browser.selectedKeys = [object.key]
            model.downloadSelection()
        }
        Button("重命名…") {
            renameTarget = object
            renameText = object.name
        }
        Divider()
        Button("删除…", role: .destructive) {
            model.browser.selectedKeys = [object.key]
            model.requestDeleteSelection()
        }
    }

    private func selectFolder(_ folder: OSSFolder, additive: Bool) {
        if additive {
            if model.browser.selectedKeys.contains(folder.prefix) {
                model.browser.selectedKeys.remove(folder.prefix)
            } else {
                model.browser.selectedKeys.insert(folder.prefix)
            }
        } else {
            model.browser.selectedKeys = [folder.prefix]
        }
    }

    private func select(_ object: OSSObject, additive: Bool) {
        if additive {
            if model.browser.selectedKeys.contains(object.key) {
                model.browser.selectedKeys.remove(object.key)
            } else {
                model.browser.selectedKeys.insert(object.key)
            }
        } else {
            model.browser.selectedKeys = [object.key]
        }
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
            model.upload(urls: urls)
        }
    }
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
                        .contextMenu {
                            pathMenu(prefix: crumb.prefix, isCurrent: crumb.prefix == model.browser.prefix)
                        }
                    }
                }
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

    @ViewBuilder
    private func pathMenu(prefix: String, isCurrent: Bool) -> some View {
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
    }
}

private struct FolderCell: View {
    let folder: OSSFolder
    var selected: Bool
    var action: () -> Void
    var onOpen: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                FinderFolderIcon(size: 64)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.3) : Color.clear)
                    }

                Text(folder.name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.clear)
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .help(folder.name)
    }
}

private struct AssetCell: View {
    let object: OSSObject
    var selected: Bool
    var action: () -> Void
    var onOpen: () -> Void

    var body: some View {
        Button(action: action) {
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
            }
        }
        .buttonStyle(PressStyle(pressedScale: 0.98))
        .help(object.name)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
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

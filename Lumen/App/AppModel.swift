import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct BannerMessage: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var isError: Bool
}

@MainActor
@Observable
final class AppModel {
    static let settingsSession = AppModel(kind: .settings)

    enum Kind {
        case window
        case settings
    }

    private let services: AppServices
    private let kind: Kind
    private let clientProvider: @MainActor (OSSAccount, OSSBucket?) throws -> OSSClient

    var accounts: [OSSAccount] {
        get { services.accounts }
        set { services.accounts = newValue }
    }
    var transfers: TransferEngine
    var settings: AppSettings
    var updates: UpdateService
    var showMenuBarExtra: Bool {
        get { services.showMenuBarExtra }
        set { services.showMenuBarExtra = newValue }
    }

    var selectedAccountID: OSSAccount.ID?
    var buckets: [OSSBucket] = []
    var selectedBucketName: String?
    var browser = BrowserModel()

    var showInspector = false
    var showAccountSheet = false
    var editingAccount: OSSAccount?
    var isLoadingBuckets = false
    var banner: BannerMessage?
    var previewItem: URL?
    var inspectorHead: ObjectHead?
    var inspectorText: String?
    var isLoadingHead = false
    var wantsDeleteConfirmation = false
    var wantsNewFolder = false
    var pendingOpenURLs: [URL] = []
    var overwritePrompt: OverwritePrompt?
    private var uploadGeneration = 0
    private var didLoadWindow = false
    private var listingRefreshTask: Task<Void, Never>?
    private var listingLoadTask: Task<ObjectListing, Error>?
    private var bucketLoadTask: Task<[OSSBucket], Error>?
    private var inspectorLoadTask: Task<(ObjectHead, String?), Error>?
    private let listingRequestGate = BrowserRequestGate()
    private let bucketRequestGate = BrowserRequestGate()
    private let inspectorRequestGate = BrowserRequestGate()

    private var lastAccountID: String {
        get { UserDefaults.standard.string(forKey: "nav.lastAccount") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nav.lastAccount") }
    }
    private var lastBucketName: String {
        get { UserDefaults.standard.string(forKey: "nav.lastBucket") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nav.lastBucket") }
    }

    var selectedAccount: OSSAccount? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    var selectedBucket: OSSBucket? {
        buckets.first(where: { $0.name == selectedBucketName })
    }

    var hasWorkspace: Bool {
        selectedAccount != nil && selectedBucket != nil
    }

    init(
        kind: Kind = .window,
        services: AppServices = .shared,
        clientProvider: @escaping @MainActor (OSSAccount, OSSBucket?) throws -> OSSClient = AppModel.defaultClient
    ) {
        self.kind = kind
        self.services = services
        self.clientProvider = clientProvider
        self.transfers = services.transfers
        self.settings = services.settings
        self.updates = services.updates
        if kind == .window, let source = services.focused {
            selectedAccountID = source.selectedAccountID
            buckets = source.buckets
            selectedBucketName = source.selectedBucketName
            browser.prefix = source.browser.prefix
            browser.viewMode = source.browser.viewMode
            browser.imagesOnly = services.settings.imagesOnly
        } else if let stored = UUID(uuidString: lastAccountID), services.accounts.contains(where: { $0.id == stored }) {
            selectedAccountID = stored
        } else {
            selectedAccountID = services.accounts.first?.id
        }
        if kind == .window {
            services.register(self)
        }
    }

    deinit {
        if kind == .window {
            // unregister is MainActor; session list is compacted on next register
        }
    }

    func becomeFocused() {
        services.register(self)
    }

    func bootstrap() {
        services.bootstrapIfNeeded()
        guard !didLoadWindow else { return }
        didLoadWindow = true
        browser.imagesOnly = settings.imagesOnly
        if selectedAccount != nil, buckets.isEmpty {
            Task { await refreshBuckets(selecting: lastBucketName.isEmpty ? nil : lastBucketName) }
        } else if selectedBucket != nil {
            Task { await refreshListing() }
        }
    }

    func pruneIfNeeded() {
        if let id = selectedAccountID, !accounts.contains(where: { $0.id == id }) {
            invalidateAllBrowserRequests()
            selectedAccountID = accounts.first?.id
            buckets = []
            selectedBucketName = nil
            browser.reset()
            if selectedAccount != nil {
                Task { await refreshBuckets() }
            }
        }
        browser.imagesOnly = settings.imagesOnly
    }

    func selectAccount(_ account: OSSAccount) {
        invalidateAllBrowserRequests()
        selectedAccountID = account.id
        lastAccountID = account.id.uuidString
        selectedBucketName = nil
        buckets = []
        browser.reset()
        Task { await refreshBuckets() }
    }

    func selectBucket(_ bucket: OSSBucket) {
        invalidateListingAndInspectorRequests()
        selectedBucketName = bucket.name
        lastBucketName = bucket.name
        browser.navigate(to: "", record: false)
        browser.backStack = []
        browser.forwardStack = []
        Task { await refreshListing() }
    }

    func openFolder(_ folder: OSSFolder) {
        invalidateListingAndInspectorRequests()
        browser.navigate(to: folder.prefix)
        Task { await refreshListing() }
    }

    func goToPrefix(_ prefix: String) {
        invalidateListingAndInspectorRequests()
        browser.navigate(to: prefix)
        Task { await refreshListing() }
    }

    func goBack() {
        guard browser.goBack() else { return }
        invalidateListingAndInspectorRequests()
        Task { await refreshListing() }
    }

    func goForward() {
        guard browser.goForward() else { return }
        invalidateListingAndInspectorRequests()
        Task { await refreshListing() }
    }

    func refreshListing() async {
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return }
        listingLoadTask?.cancel()
        let prefix = browser.prefix
        let context = listingRequestGate.begin(
            accountID: accountID,
            bucketName: bucketName,
            prefix: prefix,
            objectKey: nil
        )
        browser.isLoading = true
        browser.errorMessage = nil
        let task = Task { try await client.listAll(prefix: prefix) }
        listingLoadTask = task
        do {
            let listing = try await task.value
            guard listingRequestGate.canCommit(context),
                  selectedAccountID == context.accountID,
                  selectedBucketName == context.bucketName,
                  browser.prefix == context.prefix
            else { return }
            browser.apply(listing, imagesOnly: settings.imagesOnly)
            if listing.isTruncated {
                present("这个文件夹里的对象很多，只加载了前几页")
            }
        } catch is CancellationError {
            // Ignore.
        } catch {
            if listingRequestGate.canCommit(context) {
                browser.errorMessage = error.localizedDescription
            }
        }
        if listingRequestGate.canCommit(context) {
            browser.isLoading = false
            listingLoadTask = nil
        }
    }

    func refreshBuckets(selecting preferred: String? = nil) async {
        guard let account = selectedAccount else { return }
        bucketLoadTask?.cancel()
        let context = bucketRequestGate.begin(
            accountID: account.id,
            bucketName: nil,
            prefix: "",
            objectKey: nil
        )
        isLoadingBuckets = true
        do {
            let client = try clientProvider(account, nil)
            let task = Task { try await client.listBuckets() }
            bucketLoadTask = task
            let list = try await task.value
            guard bucketRequestGate.canCommit(context), selectedAccountID == context.accountID else { return }
            buckets = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let current = selectedBucketName
            if let current, buckets.contains(where: { $0.name == current }) {
                lastBucketName = current
                if browser.objects.isEmpty && browser.folders.isEmpty {
                    await refreshListing()
                }
            } else if let preferred, let match = buckets.first(where: { $0.name == preferred }) {
                selectBucket(match)
            } else if let first = buckets.first {
                selectBucket(first)
            }
        } catch is CancellationError {
            // A newer account request replaced this one.
        } catch {
            if bucketRequestGate.canCommit(context) {
                present(error.localizedDescription, error: true)
            }
        }
        if bucketRequestGate.canCommit(context) {
            isLoadingBuckets = false
            bucketLoadTask = nil
        }
    }

    func makeClient() -> OSSClient? {
        guard let account = selectedAccount else { return nil }
        do {
            return try clientProvider(account, selectedBucket)
        } catch {
            present(error.localizedDescription, error: true)
            return nil
        }
    }

    func saveAccount(_ draft: AccountDraft) async throws {
        let region = draft.regionID
        let creds = OSSCredentials(
            accessKeyId: draft.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeySecret: draft.secret,
            securityToken: draft.token.isEmpty ? nil : draft.token
        )
        let probe = OSSClient(
            credentials: creds,
            region: region,
            endpointHost: OSSAccount(
                id: draft.id,
                name: draft.name,
                accessKeyId: creds.accessKeyId,
                regionID: region,
                endpointOverride: draft.endpointOverride,
                cdnDomain: draft.cdnDomain,
                defaultACL: draft.defaultACL,
                prefixTemplate: draft.prefixTemplate,
                useTransferAccelerate: draft.useTransferAccelerate,
                createdAt: draft.createdAt
            ).apiHost(for: nil),
            bucket: nil
        )
        let found = try await probe.listBuckets()
        let account = OSSAccount(
            id: draft.id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeyId: creds.accessKeyId,
            regionID: region,
            endpointOverride: draft.endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            cdnDomain: draft.cdnDomain.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultACL: draft.defaultACL,
            prefixTemplate: draft.prefixTemplate,
            useTransferAccelerate: draft.useTransferAccelerate,
            createdAt: draft.createdAt
        )
        try AccountStore.storeSecrets(id: account.id, secret: draft.secret, token: draft.token)
        var updatedAccounts = accounts
        if let index = updatedAccounts.firstIndex(where: { $0.id == account.id }) {
            updatedAccounts[index] = account
        } else {
            updatedAccounts.append(account)
        }
        try AccountStore.save(updatedAccounts)
        accounts = updatedAccounts
        buckets = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedAccountID = account.id
        lastAccountID = account.id.uuidString
        let keep = selectedBucketName
        if let keep, buckets.contains(where: { $0.name == keep }) {
            selectedBucketName = keep
            lastBucketName = keep
            await refreshListing()
        } else if let first = buckets.first {
            selectBucket(first)
        }
        present("已连接，共 \(found.count) 个存储空间")
        if !pendingOpenURLs.isEmpty, hasWorkspace {
            let queued = pendingOpenURLs
            pendingOpenURLs = []
            upload(urls: queued)
        }
    }

    func deleteAccount(_ account: OSSAccount) {
        let updatedAccounts = accounts.filter { $0.id != account.id }
        do {
            try AccountStore.save(updatedAccounts)
        } catch {
            present("无法保存账号更改：\(error.localizedDescription)", error: true)
            return
        }
        accounts = updatedAccounts
        AccountStore.deleteSecrets(id: account.id)
        services.sessions.forEach { $0.pruneIfNeeded() }
        pruneIfNeeded()
    }

    func upload(urls: [URL], to prefix: String? = nil, applyTemplate: Bool? = nil) {
        guard makeClient() != nil, selectedAccount != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            showAccountSheet = accounts.isEmpty
            present("先添加账号并选择存储空间", error: true)
            return
        }
        let dest = prefix ?? browser.prefix
        let useTemplate = applyTemplate ?? dest.isEmpty
        Task { await beginUpload(urls: urls, prefix: dest, applyTemplate: useTemplate) }
    }

    func confirmOverwrite() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        commit(plan: prompt.plan, client: prompt.client, account: prompt.account, bucket: prompt.bucket)
    }

    func skipOverwriteConflicts() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        commit(
            plan: prompt.plan,
            client: prompt.client,
            account: prompt.account,
            bucket: prompt.bucket,
            excludingSources: prompt.skipSources
        )
    }

    func cancelOverwrite() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        transfers.abandon(plan: prompt.plan)
    }

    private func beginUpload(urls: [URL], prefix: String, applyTemplate: Bool) async {
        guard let client = makeClient(), let account = selectedAccount else { return }
        uploadGeneration += 1
        let generation = uploadGeneration
        if overwritePrompt != nil {
            cancelOverwrite()
        }
        let plan = TransferEngine.planUploads(
            urls: urls,
            prefix: prefix,
            template: account.prefixTemplate,
            applyTemplate: applyTemplate,
            settings: settings
        )
        if plan.skipped > 0 {
            present("已跳过 \(plan.skipped) 个不支持的文件")
        }
        let viable = plan.items.filter { $0.failure == nil }
        guard !viable.isEmpty else {
            transfers.enqueue(plan: plan, client: client, account: account, bucket: selectedBucket, settings: settings)
            return
        }
        let existing: Set<String>
        do {
            existing = try await existingKeys(among: viable.map(\.objectKey))
        } catch {
            transfers.abandon(plan: plan)
            present("无法确认目标是否已有同名文件，已取消上传", error: true)
            return
        }
        guard generation == uploadGeneration else {
            transfers.abandon(plan: plan)
            return
        }
        var seen = Set<String>()
        var conflicts: [String] = []
        var skipSources: Set<URL> = []
        for item in viable {
            if existing.contains(item.objectKey) || seen.contains(item.objectKey) {
                let label = PathTemplate.relative(item.objectKey, under: prefix)
                if !conflicts.contains(label) {
                    conflicts.append(label)
                }
                skipSources.insert(item.sourceURL)
            }
            seen.insert(item.objectKey)
        }
        if conflicts.isEmpty {
            commit(plan: plan, client: client, account: account, bucket: selectedBucket)
            return
        }
        overwritePrompt = OverwritePrompt(
            plan: plan,
            client: client,
            account: account,
            bucket: selectedBucket,
            conflicts: conflicts,
            skipSources: skipSources
        )
    }

    private func commit(
        plan: TransferEngine.UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        excludingSources: Set<URL> = []
    ) {
        transfers.enqueue(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
            settings: settings,
            excludingSources: excludingSources
        )
        scheduleListingRefresh()
    }

    private func existingKeys(among keys: [String]) async throws -> Set<String> {
        guard let client = makeClient() else {
            throw OSSServiceError(statusCode: 0, code: "NoClient", message: "还没有连接", requestId: "")
        }
        let unique = Array(Set(keys))
        if unique.count > 40 {
            let parents = Set(unique.map { PathTemplate.parentPrefix($0) })
            var found = Set<String>()
            for parent in parents {
                let listing = try await client.listAllObjects(prefix: parent)
                if listing.truncated {
                    throw OSSServiceError(statusCode: 0, code: "IncompleteList", message: "无法完整确认是否重名", requestId: "")
                }
                found.formUnion(listing.objects.map(\.key))
            }
            return found.intersection(unique)
        }
        var found = Set<String>()
        for key in unique {
            if try await client.objectExists(key: key) {
                found.insert(key)
            }
        }
        return found
    }

    func ingestIncoming(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
    }

    func confirmPendingOpen() {
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        upload(urls: urls)
    }

    func cancelPendingOpen() {
        pendingOpenURLs = []
    }

    func requestDeleteSelection() {
        guard !browser.selectedKeys.isEmpty else { return }
        wantsDeleteConfirmation = true
    }

    var deleteDialogTitle: String {
        let folders = browser.selectedFolders
        let files = browser.selectedObjects
        let count = folders.count + files.count
        if count <= 1, let folder = folders.first, files.isEmpty {
            return "删除文件夹“\(folder.name)”？"
        }
        if count <= 1, let file = files.first {
            return "删除“\(file.name)”？"
        }
        return "删除 \(max(count, browser.selectedKeys.count)) 项？"
    }

    var deleteDialogMessage: String {
        let folders = browser.selectedFolders
        let files = browser.selectedObjects
        var lines: [String] = folders.prefix(8).map { "\($0.name)/" }
        let remain = 8 - lines.count
        if remain > 0 {
            lines.append(contentsOf: files.prefix(remain).map(\.name))
        }
        let extra = folders.count + files.count - lines.count
        var text = lines.joined(separator: "\n")
        if extra > 0 {
            text += "\n以及另外 \(extra) 项"
        }
        if !folders.isEmpty {
            text += (text.isEmpty ? "" : "\n") + "文件夹里的对象会一并从 OSS 删除，无法恢复。"
        } else if !text.isEmpty {
            text += "\n删除后无法恢复。"
        }
        return text
    }

    func scheduleListingRefresh() {
        listingRefreshTask?.cancel()
        listingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.refreshListing()
        }
    }

    func createFolder(named raw: String) async {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !name.isEmpty, let client = makeClient() else { return }
        let key = PathTemplate.join(browser.prefix, key: name) + "/"
        do {
            try await client.putData(key: key, data: Data(), contentType: "application/x-directory", acl: .default)
            await refreshListing()
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func deleteSelection() async {
        guard let client = makeClient() else { return }
        let keys = Array(browser.selectedKeys)
        guard !keys.isEmpty else { return }
        do {
            for key in keys {
                if key.hasSuffix("/") {
                    try await deletePrefix(key, client: client)
                } else {
                    try await client.deleteObject(key: key)
                }
            }
            browser.selectedKeys = []
            await refreshListing()
            Haptics.alignment()
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func deleteFolder(_ folder: OSSFolder) async {
        guard let client = makeClient() else { return }
        do {
            try await deletePrefix(folder.prefix, client: client)
            await refreshListing()
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    private func deletePrefix(_ prefix: String, client: OSSClient) async throws {
        let listing = try await client.listAllObjects(prefix: prefix, includePlaceholders: true)
        if listing.truncated {
            throw OSSServiceError(
                statusCode: 0,
                code: "IncompleteList",
                message: "目录未列完，已取消删除，以免漏删",
                requestId: ""
            )
        }
        for object in listing.objects.sorted(by: { $0.key.count > $1.key.count }) {
            try await client.deleteObject(key: object.key)
        }
        try? await client.deleteObject(key: prefix)
    }

    func rename(_ object: OSSObject, to raw: String) async {
        guard let client = makeClient() else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dest = PathTemplate.join(PathTemplate.parentPrefix(object.key), key: name)
        guard dest != object.key else { return }
        do {
            try await client.copyObject(from: object.key, to: dest)
            try await client.deleteObject(key: object.key)
            await refreshListing()
            browser.selectedKeys = [dest]
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func downloadSelection() {
        let objects = browser.selectedObjects
        let folders = browser.selectedFolders
        guard !objects.isEmpty || !folders.isEmpty else { return }
        guard let dest = chooseDownloadDirectory() else { return }
        Task { await startDownloads(objects: objects, folders: folders, to: dest) }
    }

    func downloadFolder(_ folder: OSSFolder) {
        guard let dest = chooseDownloadDirectory(message: "下载“\(folder.name)”到") else { return }
        Task { await startDownloads(objects: [], folders: [folder], to: dest) }
    }

    func downloadCurrentPrefix() {
        guard selectedBucket != nil else { return }
        let prefix = browser.prefix
        let name = prefix.isEmpty ? (selectedBucket?.name ?? "bucket") : PathTemplate.lastComponent(prefix)
        guard let dest = chooseDownloadDirectory(message: "下载“\(name)”到") else { return }
        Task { await startDownloads(objects: [], folders: [], to: dest, extraPrefix: (prefix, name)) }
    }

    private func chooseDownloadDirectory(message: String = "选择下载位置") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "存储"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func startDownloads(
        objects: [OSSObject],
        folders: [OSSFolder],
        to dest: URL,
        extraPrefix: (prefix: String, folderName: String)? = nil
    ) async {
        guard let client = makeClient() else { return }
        var items: [(object: OSSObject, destination: URL)] = []
        var skippedLocal = 0
        for object in objects {
            guard let name = PathTemplate.sanitizedRelative(object.name) else { continue }
            let url = dest.appending(path: name)
            guard PathTemplate.isInside(url, root: dest) else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                skippedLocal += 1
                continue
            }
            items.append((object: object, destination: url))
        }
        var truncated = false
        var prefixes: [(String, String)] = folders.map { ($0.prefix, $0.name) }
        if let extraPrefix {
            prefixes.append(extraPrefix)
        }
        if !prefixes.isEmpty {
            present("正在列出要下载的文件…")
        }
        for (prefix, folderName) in prefixes {
            do {
                let listing = try await client.listAllObjects(prefix: prefix)
                if listing.truncated { truncated = true }
                if listing.objects.isEmpty {
                    present("“\(folderName)”里没有可下载的文件", error: true)
                    continue
                }
                guard let safeName = PathTemplate.sanitizedRelative(folderName) else { continue }
                let root = dest.appending(path: safeName, directoryHint: .isDirectory)
                guard PathTemplate.isInside(root, root: dest) else { continue }
                for object in listing.objects {
                    let relative = PathTemplate.relative(object.key, under: prefix)
                    guard let safe = PathTemplate.sanitizedRelative(relative) else { continue }
                    let url = root.appending(path: safe)
                    guard PathTemplate.isInside(url, root: dest) else { continue }
                    if FileManager.default.fileExists(atPath: url.path) {
                        skippedLocal += 1
                        continue
                    }
                    items.append((object: object, destination: url))
                }
            } catch {
                present(error.localizedDescription, error: true)
                return
            }
        }
        guard !items.isEmpty else {
            if skippedLocal > 0 {
                present("本地已有同名文件，已跳过 \(skippedLocal) 项")
            }
            return
        }
        transfers.enqueueDownloadJobs(items: items, client: client, scopedRoot: dest)
        if truncated {
            present("已加入 \(items.count) 个下载，部分目录未列完")
        } else if skippedLocal > 0 {
            present("已加入 \(items.count) 个下载，跳过 \(skippedLocal) 个本地已存在的文件")
        } else if items.count > 1 {
            present("已加入 \(items.count) 个下载")
        }
    }

    func copyURLs(style: LinkStyle = .plain) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        let client = account.prefersSignedLinks ? makeClient() : nil
        var usedSigned = false
        let urls = browser.selectedObjects.compactMap { object -> String? in
            let resolved: URL?
            if let client, let signed = client.presignedURL(key: object.key) {
                usedSigned = true
                resolved = signed
            } else {
                resolved = account.publicURL(bucketName: bucket.name, bucket: bucket, key: object.key)
            }
            guard let url = resolved else { return nil }
            switch style {
            case .plain: return url.absoluteString
            case .markdown:
                return LinkEscaping.markdownImage(name: object.name, url: url.absoluteString)
            case .html:
                return LinkEscaping.htmlImage(name: object.name, url: url.absoluteString)
            }
        }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        Haptics.alignment()
        present(usedSigned ? "已复制签名链接，1 小时内有效" : "已复制 \(urls.count) 条链接")
    }

    func loadInspector() async {
        guard let object = browser.primarySelection, let client = makeClient() else {
            inspectorLoadTask?.cancel()
            inspectorRequestGate.invalidate()
            inspectorHead = nil
            inspectorText = nil
            isLoadingHead = false
            return
        }
        inspectorLoadTask?.cancel()
        let context = inspectorRequestGate.begin(
            accountID: selectedAccountID,
            bucketName: selectedBucketName,
            prefix: browser.prefix,
            objectKey: object.key
        )
        isLoadingHead = true
        inspectorText = nil
        let task = Task { () throws -> (ObjectHead, String?) in
            let head = try await client.head(key: object.key)
            var text: String?
            if object.isText,
               object.size <= 512_000,
               let data = try? await client.objectData(key: object.key) {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            }
            return (head, text)
        }
        inspectorLoadTask = task
        do {
            let (head, text) = try await task.value
            guard inspectorRequestGate.canCommit(context),
                  browser.primarySelection?.key == context.objectKey
            else { return }
            inspectorHead = head
            inspectorText = text
        } catch is CancellationError {
            // A newer selection replaced this one.
        } catch {
            if inspectorRequestGate.canCommit(context) {
                inspectorHead = nil
                inspectorText = nil
            }
        }
        if inspectorRequestGate.canCommit(context) {
            isLoadingHead = false
            inspectorLoadTask = nil
        }
    }

    func quickLookSelection() async {
        guard let object = browser.primarySelection, let client = makeClient() else { return }
        let dest = FileManager.default.temporaryDirectory.appending(path: "\(object.etag)-\(object.name)")
        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                try await client.download(key: object.key, to: dest)
            }
            previewItem = dest
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func copyFolderPath(_ prefix: String, includeBucket: Bool) {
        let text: String
        if includeBucket, let bucket = selectedBucket {
            text = prefix.isEmpty ? bucket.name : "\(bucket.name)/\(prefix)"
        } else {
            text = prefix.isEmpty ? "/" : prefix
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        present("已复制路径")
    }

    func copyFolderURL(_ prefix: String) {
        guard let account = selectedAccount, let bucket = selectedBucket,
              let url = account.publicURL(bucketName: bucket.name, bucket: bucket, key: prefix)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        present("已复制链接")
    }

    func present(_ text: String, error: Bool = false) {
        banner = BannerMessage(text: text, isError: error)
    }

    func pasteFromClipboard() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            upload(urls: urls)
            return
        }
        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            var files: [URL] = []
            for image in images {
                if let url = Self.writeTemporaryJPEG(image) {
                    files.append(url)
                }
            }
            if !files.isEmpty {
                upload(urls: files)
            }
        }
    }

    private static func writeTemporaryJPEG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString).jpg")
        try? data.write(to: url)
        return url
    }

    private static func defaultClient(account: OSSAccount, bucket: OSSBucket?) throws -> OSSClient {
        let credentials = try AccountStore.credentials(for: account)
        var client = OSSClient(
            credentials: credentials,
            region: account.signingRegion(for: bucket),
            endpointHost: account.apiHost(for: bucket),
            bucket: bucket?.name
        )
        if let bucket {
            client = client.scoped(to: bucket, account: account)
        }
        return client
    }

    private func invalidateListingAndInspectorRequests() {
        listingLoadTask?.cancel()
        listingLoadTask = nil
        listingRequestGate.invalidate()
        browser.isLoading = false
        inspectorLoadTask?.cancel()
        inspectorLoadTask = nil
        inspectorRequestGate.invalidate()
        inspectorHead = nil
        inspectorText = nil
        isLoadingHead = false
    }

    private func invalidateAllBrowserRequests() {
        bucketLoadTask?.cancel()
        bucketLoadTask = nil
        bucketRequestGate.invalidate()
        isLoadingBuckets = false
        invalidateListingAndInspectorRequests()
    }
}

enum LinkStyle {
    case plain, markdown, html
}

struct OverwritePrompt: Identifiable {
    let id = UUID()
    var plan: TransferEngine.UploadPlan
    var client: OSSClient
    var account: OSSAccount
    var bucket: OSSBucket?
    var conflicts: [String]
    var skipSources: Set<URL>

    var title: String {
        conflicts.count == 1 ? "“\(conflicts[0])”已存在" : "\(conflicts.count) 个文件已存在"
    }

    var message: String {
        let shown = conflicts.prefix(12)
        var text = shown.joined(separator: "\n")
        if conflicts.count > shown.count {
            text += "\n以及另外 \(conflicts.count - shown.count) 个"
        }
        text += "\n覆盖后无法恢复原来的对象。"
        return text
    }
}

struct AccountDraft: Identifiable {
    var id: UUID
    var name: String
    var accessKeyId: String
    var secret: String
    var token: String
    var regionID: String
    var endpointOverride: String
    var cdnDomain: String
    var defaultACL: ObjectACL
    var prefixTemplate: String
    var useTransferAccelerate: Bool
    var createdAt: Date

    static func fresh() -> AccountDraft {
        AccountDraft(
            id: UUID(),
            name: "",
            accessKeyId: "",
            secret: "",
            token: "",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .publicRead,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
    }

    static func from(_ account: OSSAccount, secret: String, token: String) -> AccountDraft {
        AccountDraft(
            id: account.id,
            name: account.name,
            accessKeyId: account.accessKeyId,
            secret: secret,
            token: token,
            regionID: account.regionID,
            endpointOverride: account.endpointOverride,
            cdnDomain: account.cdnDomain,
            defaultACL: account.defaultACL,
            prefixTemplate: account.prefixTemplate,
            useTransferAccelerate: account.useTransferAccelerate,
            createdAt: account.createdAt
        )
    }
}

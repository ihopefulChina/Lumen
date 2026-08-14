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
    var updates: AppUpdater
    var favorites: FavoriteStore
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
    var previewItem: URL? {
        didSet {
            guard let oldValue,
                  oldValue != previewItem,
                  ownedPreviewURLs.remove(oldValue) != nil
            else { return }
            try? FileManager.default.removeItem(at: oldValue)
        }
    }
    var inspectorHead: ObjectHead?
    var inspectorText: String?
    var isLoadingHead = false
    var wantsDeleteConfirmation = false
    var wantsNewFolder = false
    var isOrganizingCloud = false
    var cloudClipboard: CloudDragPayload?
    var pendingOpenURLs: [URL] = []
    private var pendingOwnedTemporaryURLs: Set<URL> = []
    private var ownedPreviewURLs: Set<URL> = []
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
        self.favorites = services.favorites
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
        selectBucket(bucket, prefix: "")
    }

    private func selectBucket(_ bucket: OSSBucket, prefix: String) {
        invalidateListingAndInspectorRequests()
        selectedBucketName = bucket.name
        lastBucketName = bucket.name
        browser.navigate(to: prefix, record: false)
        browser.backStack = []
        browser.forwardStack = []
        Task { await refreshListing() }
    }

    func openFolder(_ folder: OSSFolder) {
        invalidateListingAndInspectorRequests()
        browser.navigate(to: folder.prefix)
        Task { await refreshListing() }
    }

    var isCurrentFolderFavorite: Bool {
        isFavorite(prefix: browser.prefix)
    }

    func isFavorite(prefix: String) -> Bool {
        guard let accountID = selectedAccountID, let bucketName = selectedBucketName else {
            return false
        }
        return favorites.contains(
            accountID: accountID,
            bucketName: bucketName,
            prefix: prefix
        )
    }

    func toggleCurrentFolderFavorite() {
        let name = browser.prefix.isEmpty
            ? (selectedBucketName ?? "存储空间")
            : PathTemplate.lastComponent(browser.prefix)
        toggleFavorite(prefix: browser.prefix, name: name)
    }

    func toggleFavorite(prefix: String, name: String) {
        guard let accountID = selectedAccountID, let bucketName = selectedBucketName else { return }
        if isFavorite(prefix: prefix) {
            favorites.remove(accountID: accountID, bucketName: bucketName, prefix: prefix)
        } else {
            favorites.add(
                FavoriteLocation(
                    accountID: accountID,
                    bucketName: bucketName,
                    prefix: prefix,
                    name: name
                )
            )
        }
    }

    func openFavorite(_ favorite: FavoriteLocation) {
        guard let account = accounts.first(where: { $0.id == favorite.accountID }) else {
            favorites.remove(favorite)
            present("这个常用位置的账号已不存在", error: true)
            return
        }

        if selectedAccountID != account.id {
            invalidateAllBrowserRequests()
            selectedAccountID = account.id
            lastAccountID = account.id.uuidString
            selectedBucketName = nil
            buckets = []
            browser.reset()
        }

        Task {
            if !buckets.contains(where: { $0.name == favorite.bucketName }) {
                await refreshBuckets(selecting: favorite.bucketName)
            }
            guard let bucket = buckets.first(where: { $0.name == favorite.bucketName }) else {
                favorites.remove(favorite)
                present("这个常用位置的存储空间已不存在", error: true)
                return
            }
            selectBucket(bucket, prefix: favorite.prefix)
        }
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
            let owned = pendingOwnedTemporaryURLs
            pendingOpenURLs = []
            pendingOwnedTemporaryURLs = []
            upload(urls: queued, ownedTemporaryURLs: owned)
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

    func upload(
        urls: [URL],
        to prefix: String? = nil,
        applyTemplate: Bool? = nil,
        ownedTemporaryURLs: Set<URL> = []
    ) {
        guard selectedAccount != nil, selectedBucket != nil, makeClient() != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            pendingOwnedTemporaryURLs.formUnion(ownedTemporaryURLs)
            showAccountSheet = accounts.isEmpty
            present("先添加账号并选择存储空间", error: true)
            return
        }
        let dest = prefix ?? browser.prefix
        let useTemplate = applyTemplate ?? dest.isEmpty
        Task {
            await beginUpload(
                urls: urls,
                prefix: dest,
                applyTemplate: useTemplate,
                ownedTemporaryURLs: ownedTemporaryURLs
            )
        }
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

    private func beginUpload(
        urls: [URL],
        prefix: String,
        applyTemplate: Bool,
        ownedTemporaryURLs: Set<URL>
    ) async {
        guard let client = makeClient(), let account = selectedAccount, let bucket = selectedBucket else {
            ownedTemporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        uploadGeneration += 1
        let generation = uploadGeneration
        if overwritePrompt != nil {
            cancelOverwrite()
        }
        let options = TransferEngine.UploadPreparationOptions(
            imagesOnly: settings.imagesOnly,
            convertHEIC: settings.convertHEIC,
            ownedTemporaryURLs: ownedTemporaryURLs
        )
        let plan = await TransferEngine.planUploads(
            urls: urls,
            prefix: prefix,
            template: account.prefixTemplate,
            applyTemplate: applyTemplate,
            options: options
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
            existing = try await existingKeys(among: viable.map(\.objectKey), client: client)
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
            commit(plan: plan, client: client, account: account, bucket: bucket)
            return
        }
        overwritePrompt = OverwritePrompt(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
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

    private func existingKeys(among keys: [String], client: OSSClient) async throws -> Set<String> {
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
        let owned = pendingOwnedTemporaryURLs
        pendingOpenURLs = []
        pendingOwnedTemporaryURLs = []
        upload(urls: urls, ownedTemporaryURLs: owned)
    }

    func cancelPendingOpen() {
        pendingOwnedTemporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        pendingOwnedTemporaryURLs = []
        pendingOpenURLs = []
    }

    func requestDeleteSelection() {
        guard !browser.actionableSelectionKeys.isEmpty else { return }
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
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return
        }
        guard let client = makeClient() else { return }
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
        let keys = Array(browser.actionableSelectionKeys)
        guard !keys.isEmpty else { return }
        do {
            for key in keys {
                if key.hasSuffix("/") {
                    try await deletePrefix(key, client: client)
                } else {
                    try await client.deleteObject(key: key)
                }
            }
            browser.clearSelection()
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
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        guard let client = makeClient() else { return }
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return
        }
        let dest = PathTemplate.join(PathTemplate.parentPrefix(object.key), key: name)
        guard dest != object.key else { return }
        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            try await client.renameObject(from: object.key, to: dest, overwrite: false)
            await refreshListing()
            browser.select(key: dest, modifiers: [])
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func renameFolder(_ folder: OSSFolder, to raw: String) async {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return }
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return
        }
        let destination = PathTemplate.join(
            PathTemplate.parentPrefix(folder.prefix),
            key: name
        ) + "/"
        guard destination != folder.prefix else { return }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            try await client.movePrefix(from: folder.prefix, to: destination)
            favorites.replacePrefix(
                accountID: accountID,
                bucketName: bucketName,
                source: folder.prefix,
                destination: destination
            )
            await refreshListing()
            browser.select(key: destination, modifiers: [])
            present("已重命名“\(folder.name)”")
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func cloudDragPayload(clickedKey: String) -> CloudDragPayload {
        let actionableKeys = browser.actionableSelectionKeys
        let keys = actionableKeys.contains(clickedKey)
            ? actionableKeys
            : [clickedKey]
        return CloudDragPayload(
            accountID: selectedAccountID ?? UUID(),
            bucketName: selectedBucketName ?? "",
            objectKeys: browser.objects.filter { keys.contains($0.key) }.map(\.key),
            folderPrefixes: browser.folders.filter { keys.contains($0.prefix) }.map(\.prefix)
        )
    }

    func copyCloudSelection(clickedKey: String) {
        let payload = cloudDragPayload(clickedKey: clickedKey)
        guard !payload.objectKeys.isEmpty || !payload.folderPrefixes.isEmpty else { return }
        cloudClipboard = payload
        let count = payload.objectKeys.count + payload.folderPrefixes.count
        present("已复制 \(count) 项，可在目标文件夹粘贴")
    }

    func pasteCloudItems() {
        guard let payload = cloudClipboard else { return }
        Task { await organizeCloud(payload, to: browser.prefix, mode: .copy) }
    }

    func moveCloudItems(_ payload: CloudDragPayload, to destinationPrefix: String) {
        Task { await organizeCloud(payload, to: destinationPrefix, mode: .move) }
    }

    func organizeCloud(
        _ payload: CloudDragPayload,
        to destinationPrefix: String,
        mode: CloudOperationMode
    ) async {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        guard payload.accountID == selectedAccountID,
              payload.bucketName == selectedBucketName
        else {
            present("只能在同一个存储空间内整理项目", error: true)
            return
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            var mappings = payload.objectKeys.map { sourceKey in
                CloudObjectMapping(
                    sourceKey: sourceKey,
                    destinationKey: PathTemplate.join(
                        destinationPrefix,
                        key: PathTemplate.lastComponent(sourceKey)
                    )
                )
            }
            var movedPrefixes: [(source: String, destination: String)] = []
            var selection = Set(mappings.map(\.destinationKey))
            for sourcePrefix in payload.folderPrefixes {
                let destination = PathTemplate.join(
                    destinationPrefix,
                    key: PathTemplate.lastComponent(sourcePrefix)
                ) + "/"
                mappings.append(contentsOf: try await client.prefixMappings(
                    from: sourcePrefix,
                    to: destination
                ))
                movedPrefixes.append((sourcePrefix, destination))
                selection.insert(destination)
            }

            try await client.performCloudOperation(mappings, mode: mode)
            if mode == .move {
                for pair in movedPrefixes {
                    favorites.replacePrefix(
                        accountID: accountID,
                        bucketName: bucketName,
                        source: pair.source,
                        destination: pair.destination
                    )
                }
            }
            browser.clearSelection()
            await refreshListing()
            browser.replaceSelection(selection)
            let count = payload.objectKeys.count + payload.folderPrefixes.count
            present(mode == .move ? "已移动 \(count) 项" : "已复制 \(count) 项")
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
        var skippedUnsafe = 0
        for object in objects {
            let url: URL
            do {
                url = try FileSafety.destination(root: dest, relativePath: object.name)
            } catch {
                skippedUnsafe += 1
                continue
            }
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
                for object in listing.objects {
                    let relative = PathTemplate.relative(object.key, under: prefix)
                    let url: URL
                    do {
                        url = try FileSafety.destination(
                            root: dest,
                            relativePath: PathTemplate.join(folderName, key: relative)
                        )
                    } catch {
                        skippedUnsafe += 1
                        continue
                    }
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
            } else if skippedUnsafe > 0 {
                present("对象路径不安全，已跳过 \(skippedUnsafe) 项", error: true)
            }
            return
        }
        transfers.enqueueDownloadJobs(items: items, client: client, scopedRoot: dest)
        if truncated {
            present("已加入 \(items.count) 个下载，部分目录未列完")
        } else if skippedLocal + skippedUnsafe > 0 {
            present("已加入 \(items.count) 个下载，跳过 \(skippedLocal + skippedUnsafe) 项")
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
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LumenQuickLook", directoryHint: .isDirectory)
        let name = (try? ObjectNameValidator.validate(object.name)) ?? "预览文件"
        let dest: URL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            dest = try FileSafety.destination(
                root: directory,
                relativePath: "\(UUID().uuidString)-\(name)"
            )
            try await client.download(key: object.key, to: dest, within: directory)
            presentPreview(at: dest)
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func presentPreview(at url: URL) {
        ownedPreviewURLs.insert(url)
        previewItem = url
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
                upload(urls: files, ownedTemporaryURLs: Set(files))
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

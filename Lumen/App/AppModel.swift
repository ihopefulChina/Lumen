import AppKit
import Foundation
import Observation

enum BannerAction: Equatable {
    case undoCloudOperation
}

struct BannerMessage: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var isError: Bool
    var action: BannerAction? = nil

    var displayDuration: Duration {
        action == nil ? .milliseconds(2_400) : .milliseconds(5_500)
    }
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
    var transferFilter: TransferFilter {
        get { services.transferFilter }
        set { services.transferFilter = newValue }
    }

    var selectedAccountID: OSSAccount.ID?
    var buckets: [OSSBucket] = []
    var selectedBucketName: String?
    var browser = BrowserModel()
    var searchScope: BucketSearchScope = .folder
    var searchFilter: BucketSearchFilter = .all
    var searchController = BucketSearchController()

    var showInspector = false
    var objectPropertiesModel: ObjectPropertiesModel?
    var showObjectProperties = false
    var crossBucketPreflight: CrossBucketPreflight?
    var showCrossBucketPreflight = false
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
    private var pendingDeleteKeys: Set<String> = []
    var wantsNewFolder = false
    var isOrganizingCloud = false {
        didSet { ProcessLifetime.setOrganizing(isOrganizingCloud) }
    }
    private(set) var lastCloudUndoOperation: CloudUndoOperation?
    private(set) var lastDeleteUndoOperation: CloudDeleteUndoOperation?
    var cloudClipboard: CloudDragPayload?
    var cloudClipboardMode: CloudOperationMode = .copy
    private var cloudClipboardChangeCount = -1
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

    var canShowInformation: Bool {
        selectedBucket != nil
    }

    var canUndoCloudOperation: Bool {
        if let deletion = lastDeleteUndoOperation {
            return !isOrganizingCloud && isCurrentScope(for: deletion)
        }
        guard let operation = lastCloudUndoOperation else { return false }
        return !isOrganizingCloud && isCurrentScope(for: operation)
    }

    var undoCloudOperationTitle: String {
        if let deletion = lastDeleteUndoOperation,
           isCurrentScope(for: deletion) {
            return deletion.title
        }
        guard let operation = lastCloudUndoOperation,
              isCurrentScope(for: operation)
        else { return "撤销" }
        return operation.title
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
        browser.viewMode = services.settings.preferredViewMode
        browser.imagesOnly = services.settings.imagesOnly
        if let stored = UUID(uuidString: lastAccountID), services.accounts.contains(where: { $0.id == stored }) {
            selectedAccountID = stored
        } else {
            selectedAccountID = services.accounts.first?.id
        }
        if kind == .window {
            services.register(self)
        }
    }

    func becomeFocused() {
        services.register(self)
    }

    func setPreferredViewMode(_ mode: BrowserViewMode) {
        settings.preferredViewMode = mode
        browser.viewMode = mode
    }

    func applyPreferredViewModeToAllSessions(_ mode: BrowserViewMode) {
        settings.preferredViewMode = mode
        for session in services.sessions {
            session.browser.viewMode = mode
        }
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

    var sidebarSelection: SidebarSelection? {
        if let accountID = selectedAccountID,
           let favorite = favorites.items.first(where: {
               $0.accountID == accountID
                   && $0.bucketName == selectedBucketName
                   && $0.prefix == browser.prefix
           }) {
            return .favorite(favorite.id)
        }
        if let name = selectedBucketName {
            return .bucket(name)
        }
        if let id = selectedAccountID {
            return .account(id)
        }
        return nil
    }

    func applySidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .account(let id):
            guard let account = accounts.first(where: { $0.id == id }),
                  selectedAccountID != id
            else { return }
            selectAccount(account)
        case .bucket(let name):
            guard let bucket = buckets.first(where: { $0.name == name }) else { return }
            if selectedBucketName == name, browser.prefix.isEmpty { return }
            selectBucket(bucket)
        case .favorite(let id):
            guard let favorite = favorites.items.first(where: { $0.id == id }) else { return }
            openFavorite(favorite)
        case nil:
            break
        }
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
        searchController.clear()
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

        let expectedAccountID = favorite.accountID
        let expectedBucketName = favorite.bucketName

        if selectedAccountID != account.id {
            invalidateAllBrowserRequests()
            selectedAccountID = account.id
            lastAccountID = account.id.uuidString
            selectedBucketName = nil
            buckets = []
            browser.reset()
        }

        Task {
            if selectedAccountID == expectedAccountID,
               !buckets.contains(where: { $0.name == expectedBucketName }) {
                await refreshBuckets(selecting: expectedBucketName)
            }
            guard selectedAccountID == expectedAccountID else { return }
            guard let bucket = buckets.first(where: { $0.name == expectedBucketName }) else {
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

    func runBucketSearch(now: Date = .now) async {
        guard searchScope == .bucket,
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName,
              let client = makeClient()
        else {
            searchController.clear()
            return
        }
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: bucketName,
            text: browser.searchText,
            filter: searchFilter
        )
        await searchController.search(query: query, now: now) { token in
            try await client.listObjectPage(prefix: "", token: token)
        }
    }

    func cancelBucketSearch() {
        searchController.cancel()
    }

    func openSearchResult(_ object: OSSObject) async {
        searchScope = .folder
        browser.searchText = ""
        searchController.clear()
        invalidateListingAndInspectorRequests()
        browser.navigate(to: PathTemplate.parentPrefix(object.key))
        await refreshListing()
        browser.replaceSelection([object.key])
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

    func testAccount(_ account: OSSAccount) async throws -> Int {
        let client = try clientProvider(account, nil)
        return try await client.listBuckets().count
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
        var updatedAccounts = accounts
        if let index = updatedAccounts.firstIndex(where: { $0.id == account.id }) {
            updatedAccounts[index] = account
        } else {
            updatedAccounts.append(account)
        }
        let previousSecret = SecretStore.get(account: AccountStore.secretAccount(account.id))
        let previousToken = SecretStore.get(account: AccountStore.tokenAccount(account.id))
        try AccountStore.save(updatedAccounts)
        do {
            try AccountStore.storeSecrets(id: account.id, secret: draft.secret, token: draft.token)
        } catch {
            try? AccountStore.save(accounts)
            if let previousSecret {
                try? AccountStore.storeSecrets(id: account.id, secret: previousSecret, token: previousToken)
            } else {
                AccountStore.deleteSecrets(id: account.id)
            }
            throw error
        }
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
        // makeClient() reports its own error (e.g. missing credentials), so
        // avoid stacking a second, misleading banner on top of it.
        let clientMissing = makeClient() == nil
        guard selectedAccount != nil, selectedBucket != nil, !clientMissing else {
            pendingOpenURLs.append(contentsOf: urls)
            pendingOwnedTemporaryURLs.formUnion(ownedTemporaryURLs)
            if selectedAccount == nil || selectedBucket == nil {
                showAccountSheet = accounts.isEmpty
                present("先添加账号并选择存储空间", error: true)
            }
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
        commit(
            plan: prompt.plan,
            client: prompt.client,
            account: prompt.account,
            bucket: prompt.bucket,
            allowOverwrite: true
        )
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
        let resolutions = TransferConflictPlanner.plan(
            keys: viable.map(\.objectKey),
            existing: existing,
            policy: settings.transferConflictPolicy
        )
        let conflicts = zip(viable, resolutions).compactMap { item, resolution -> String? in
            guard resolution == .ask else { return nil }
            return PathTemplate.relative(item.objectKey, under: prefix)
        }
        if !conflicts.isEmpty {
            let skipSources = Set(zip(viable, resolutions).compactMap { item, resolution in
                resolution == .ask ? item.sourceURL : nil
            })
            overwritePrompt = OverwritePrompt(
                plan: plan,
                client: client,
                account: account,
                bucket: bucket,
                conflicts: Array(Set(conflicts)).sorted(),
                skipSources: skipSources
            )
            return
        }

        var resolvedPlan = plan
        var resolutionIndex = 0
        var excludedSources = Set<URL>()
        for index in resolvedPlan.items.indices where resolvedPlan.items[index].failure == nil {
            switch resolutions[resolutionIndex] {
            case .renamed(let key):
                resolvedPlan.items[index].objectKey = key
            case .skip:
                excludedSources.insert(resolvedPlan.items[index].sourceURL)
            case .useOriginal, .ask:
                break
            }
            resolutionIndex += 1
        }
        commit(
            plan: resolvedPlan,
            client: client,
            account: account,
            bucket: bucket,
            excludingSources: excludedSources,
            allowOverwrite: settings.transferConflictPolicy == .replace
        )
    }

    private func commit(
        plan: TransferEngine.UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        excludingSources: Set<URL> = [],
        allowOverwrite: Bool = false
    ) {
        transfers.enqueue(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
            settings: settings,
            excludingSources: excludingSources,
            allowOverwrite: allowOverwrite
        )
        scheduleListingRefresh()
    }

    func existingKeys(among keys: [String], client: OSSClient) async throws -> Set<String> {
        let unique = Array(Set(keys))
        if unique.count > 40 {
            let parents = Set(unique.map { PathTemplate.parentPrefix($0) })
            var found = Set<String>()
            for parent in parents {
                let listing = try await client.listAllObjects(prefix: parent)
                if listing.truncated {
                    for key in unique where PathTemplate.parentPrefix(key) == parent {
                        if try await client.objectExists(key: key) {
                            found.insert(key)
                        }
                    }
                    continue
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
        requestDeleteSelection(keys: browser.actionableSelectionKeys)
    }

    func requestDeleteSelection(keys: Set<String>, deferConfirmation: Bool = false) {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        // Restrict to what the browser actually shows and what deleteSelection
        // will act on, so the confirmation dialog never over-counts.
        let known = Set(keys.filter { browser.visibleKeys.contains($0) })
        guard !known.isEmpty else { return }
        pendingDeleteKeys = known
        browser.replaceSelection(known)
        if deferConfirmation {
            DispatchQueue.main.async { [weak self] in
                self?.wantsDeleteConfirmation = true
            }
        } else {
            wantsDeleteConfirmation = true
        }
    }

    func cancelPendingDelete() {
        pendingDeleteKeys = []
    }

    private var deleteTargetFolders: [OSSFolder] {
        browser.folders.filter { pendingDeleteKeys.contains($0.prefix) }
    }

    private var deleteTargetObjects: [OSSObject] {
        browser.objects.filter { pendingDeleteKeys.contains($0.key) }
    }

    var deleteDialogTitle: String {
        let folders = deleteTargetFolders
        let files = deleteTargetObjects
        let count = folders.count + files.count
        if count <= 1, let folder = folders.first, files.isEmpty {
            return "删除文件夹“\(folder.name)”？"
        }
        if count <= 1, let file = files.first {
            return "删除“\(file.name)”？"
        }
        return "删除 \(max(count, pendingDeleteKeys.count)) 项？"
    }

    var deleteDialogMessage: String {
        let folders = deleteTargetFolders
        let files = deleteTargetObjects
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
            text += (text.isEmpty ? "" : "\n") + "文件夹里的对象会一并从 OSS 删除。"
        } else if !text.isEmpty {
            text += "\n将从 OSS 删除。"
        }
        text += "\n若 Bucket 已开启版本控制，可立即撤销；否则删除是永久的。"
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
            noteBucketMutated()
            await refreshListing()
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func deleteSelection() async {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return }
        let selectedKeys = pendingDeleteKeys.isEmpty ? browser.actionableSelectionKeys : pendingDeleteKeys
        pendingDeleteKeys = []
        let keys = browser.orderedVisibleKeys.filter(selectedKeys.contains)
        guard !keys.isEmpty else { return }
        let previousCloudUndo = lastCloudUndoOperation
        let previousDeleteUndo = lastDeleteUndoOperation
        var receipts: [OSSDeleteReceipt] = []
        do {
            for key in keys {
                if key.hasSuffix("/") {
                    try await deletePrefix(key, client: client) { receipt in
                        receipts.append(receipt)
                    }
                } else {
                    receipts.append(try await client.deleteObject(key: key))
                }
            }
            lastCloudUndoOperation = nil
            recordDeleteUndo(
                receipts: receipts,
                sourceSelection: Set(keys),
                accountID: accountID,
                bucketName: bucketName
            )
            noteBucketMutated()
            browser.clearSelection()
            await refreshListing()
            Haptics.alignment()
            present(
                keys.count == 1 ? "已删除 1 项" : "已删除 \(keys.count) 项",
                action: lastDeleteUndoOperation == nil ? nil : .undoCloudOperation
            )
        } catch {
            guard !receipts.isEmpty else {
                lastCloudUndoOperation = previousCloudUndo
                lastDeleteUndoOperation = previousDeleteUndo
                present(error.localizedDescription, error: true)
                return
            }
            lastCloudUndoOperation = nil
            recordDeleteUndo(
                receipts: receipts,
                sourceSelection: Set(receipts.map(\.key)),
                accountID: accountID,
                bucketName: bucketName
            )
            noteBucketMutated()
            await refreshListing()
            present(
                "已删除 \(receipts.count) 个对象，之后失败：\(error.localizedDescription)",
                error: true,
                action: lastDeleteUndoOperation == nil ? nil : .undoCloudOperation
            )
        }
    }

    private func deletePrefix(
        _ prefix: String,
        client: OSSClient,
        onDeleted: (OSSDeleteReceipt) -> Void
    ) async throws {
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
            onDeleted(try await client.deleteObject(key: object.key))
        }
    }

    private func recordDeleteUndo(
        receipts: [OSSDeleteReceipt],
        sourceSelection: Set<String>,
        accountID: UUID,
        bucketName: String
    ) {
        let markers = receipts.compactMap(\.undoMarker)
        guard !markers.isEmpty, markers.count == receipts.count else {
            lastDeleteUndoOperation = nil
            return
        }
        lastDeleteUndoOperation = CloudDeleteUndoOperation(
            accountID: accountID,
            bucketName: bucketName,
            title: "撤销删除",
            markers: markers,
            sourceSelection: sourceSelection
        )
    }

    @discardableResult
    func rename(_ object: OSSObject, to raw: String) async -> Bool {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return false
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return false }
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
        let dest = PathTemplate.join(PathTemplate.parentPrefix(object.key), key: name)
        guard dest != object.key else { return true }
        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            try await client.renameObject(from: object.key, to: dest, overwrite: false)
            noteBucketMutated()
            await refreshListing()
            browser.select(key: dest, modifiers: [])
            lastDeleteUndoOperation = nil
            lastCloudUndoOperation = CloudUndoOperation(
                accountID: accountID,
                bucketName: bucketName,
                title: "撤销重命名",
                mappings: [
                    CloudObjectMapping(sourceKey: object.key, destinationKey: dest)
                ],
                favoriteMoves: [],
                sourceSelection: [object.key],
                destinationSelection: [dest]
            )
            present("已重命名“\(name)”", action: .undoCloudOperation)
            return true
        } catch CloudObjectOperationError.sourceCleanupFailed {
            // Copy committed but the source delete failed: the object now
            // exists under both names. Refresh so the browser shows the truth.
            await refreshListing()
            present("目标已复制完成，但未能删除原文件", error: true)
            return false
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
    }

    @discardableResult
    func renameFolder(_ folder: OSSFolder, to raw: String) async -> Bool {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return false
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return false }
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
        let destination = PathTemplate.join(
            PathTemplate.parentPrefix(folder.prefix),
            key: name
        ) + "/"
        guard destination != folder.prefix else { return true }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            let mappings = try await client.prefixMappings(
                from: folder.prefix,
                to: destination
            )
            try await client.performCloudOperation(mappings, mode: .move)
            favorites.replacePrefix(
                accountID: accountID,
                bucketName: bucketName,
                source: folder.prefix,
                destination: destination
            )
            noteBucketMutated()
            await refreshListing()
            browser.select(key: destination, modifiers: [])
            lastDeleteUndoOperation = nil
            lastCloudUndoOperation = CloudUndoOperation(
                accountID: accountID,
                bucketName: bucketName,
                title: "撤销重命名",
                mappings: mappings,
                favoriteMoves: [
                    CloudFavoriteMove(
                        sourcePrefix: folder.prefix,
                        destinationPrefix: destination
                    )
                ],
                sourceSelection: [folder.prefix],
                destinationSelection: [destination]
            )
            present("已重命名“\(folder.name)”", action: .undoCloudOperation)
            return true
        } catch CloudObjectOperationError.sourceCleanupFailed {
            // A folder rename is a copy-then-delete of every object in it and
            // can partially succeed; refresh so the listing shows the truth.
            await refreshListing()
            present("目标已复制完成，但未能删除部分原文件", error: true)
            return false
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
    }

    func cloudDragPayload(clickedKey: String) -> CloudDragPayload {
        let actionableKeys = browser.actionableSelectionKeys
        let keys: Set<String>
        if actionableKeys.contains(clickedKey) {
            keys = actionableKeys
        } else if browser.visibleKeys.contains(clickedKey) {
            keys = [clickedKey]
        } else {
            keys = []
        }
        return CloudDragPayload(
            accountID: selectedAccountID ?? UUID(),
            bucketName: selectedBucketName ?? "",
            sourceRegionID: selectedBucket?.regionID ?? selectedAccount?.regionID,
            objectKeys: browser.visibleObjects.filter { keys.contains($0.key) }.map(\.key),
            folderPrefixes: browser.visibleFolders.filter { keys.contains($0.prefix) }.map(\.prefix)
        )
    }

    func finderItemProvider(clickedKey: String) -> NSItemProvider {
        let payload = cloudDragPayload(clickedKey: clickedKey)
        guard (!payload.objectKeys.isEmpty || !payload.folderPrefixes.isEmpty),
              let client = makeClient()
        else { return NSItemProvider() }
        return FinderExportCoordinator.itemProvider(
            for: payload,
            client: client,
            speedLimit: settings.downloadSpeedLimit
        )
    }

    func presentObjectProperties(for object: OSSObject) {
        guard let client = makeClient() else { return }
        objectPropertiesModel = ObjectPropertiesModel(
            object: object,
            client: client,
            onSaved: { [weak self] in self?.didSaveObjectProperties() }
        )
        showObjectProperties = true
    }

    private func didSaveObjectProperties() {
        noteBucketMutated()
        scheduleListingRefresh()
        Task { await loadInspector() }
        present("对象属性已保存到云端")
    }

    func noteBucketMutated(accountID: UUID? = nil, bucketName: String? = nil) {
        if let accountID, let bucketName {
            searchController.invalidate(accountID: accountID, bucketName: bucketName)
            return
        }
        if let selectedAccountID, let selectedBucketName {
            searchController.invalidate(accountID: selectedAccountID, bucketName: selectedBucketName)
        }
    }

    var canCopyCloudItems: Bool {
        !browser.actionableSelectionKeys.isEmpty
    }

    var resolvedClipboardItem: CloudClipboardItem? {
        if let item = CloudClipboard.read() {
            return item
        }
        if let payload = cloudClipboard,
           NSPasteboard.general.changeCount == cloudClipboardChangeCount
        {
            return CloudClipboardItem(payload: payload, mode: cloudClipboardMode)
        }
        return nil
    }

    var resolvedCloudClipboard: CloudDragPayload? {
        resolvedClipboardItem?.payload
    }

    var canPasteCloudItems: Bool {
        resolvedClipboardItem != nil || cloudClipboard != nil
    }

    var canPaste: Bool {
        canPasteCloudItems || hasFileURLsOnPasteboard
    }

    var pasteMenuTitle: String {
        clipboardMode == .move ? "移动到此处" : "粘贴"
    }

    var pasteIntoFolderTitle: String {
        clipboardMode == .move ? "移动到此文件夹" : "粘贴到此文件夹"
    }

    private var clipboardMode: CloudOperationMode {
        resolvedClipboardItem?.mode ?? cloudClipboardMode
    }

    func copyCloudSelection(clickedKey: String? = nil) {
        rememberSelectionOnClipboard(clickedKey: clickedKey, mode: .copy)
    }

    func cutCloudSelection(clickedKey: String? = nil) {
        rememberSelectionOnClipboard(clickedKey: clickedKey, mode: .move)
    }

    func paste(into destinationPrefix: String? = nil) {
        let destination = destinationPrefix ?? browser.prefix
        if let item = resolvedClipboardItem
            ?? cloudClipboard.map({ CloudClipboardItem(payload: $0, mode: cloudClipboardMode) })
        {
            if item.mode == .move,
               CloudObjectOperation.staysInPlace(
                objectKeys: item.payload.objectKeys,
                folderPrefixes: item.payload.folderPrefixes,
                destinationPrefix: destination
               )
            {
                present("项目已经在这个位置")
                return
            }
            Task {
                let succeeded = await organizeCloud(item.payload, to: destination, mode: item.mode)
                if succeeded, item.mode == .move {
                    clearCloudClipboard()
                }
            }
            return
        }
        pasteFromClipboard(to: destination)
    }

    func pasteCloudItems(into destinationPrefix: String? = nil) {
        paste(into: destinationPrefix)
    }

    private func rememberSelectionOnClipboard(clickedKey: String?, mode: CloudOperationMode) {
        let key = clickedKey
            ?? browser.actionableSelectionKeys.sorted().first
            ?? ""
        let payload = cloudDragPayload(clickedKey: key)
        guard !payload.isEmpty else { return }
        rememberCloudClipboard(payload, mode: mode)
        if mode == .move {
            present("已剪切 \(payload.itemCount) 项")
        } else {
            present("已复制 \(payload.itemCount) 项")
        }
    }

    private func rememberCloudClipboard(_ payload: CloudDragPayload, mode: CloudOperationMode) {
        cloudClipboard = payload
        cloudClipboardMode = mode
        CloudClipboard.write(payload, mode: mode)
        cloudClipboardChangeCount = NSPasteboard.general.changeCount
    }

    private func clearCloudClipboard() {
        cloudClipboard = nil
        cloudClipboardMode = .copy
        cloudClipboardChangeCount = -1
        CloudClipboard.clear()
    }

    func moveCloudItems(_ payload: CloudDragPayload, to destinationPrefix: String) {
        Task { await organizeCloud(payload, to: destinationPrefix, mode: .move) }
    }

    @discardableResult
    func organizeCloud(
        _ payload: CloudDragPayload,
        to destinationPrefix: String,
        mode: CloudOperationMode
    ) async -> Bool {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return false
        }
        guard payload.accountID == selectedAccountID,
              payload.bucketName == selectedBucketName
        else {
            await prepareCrossBucketOperation(payload, to: destinationPrefix, mode: mode)
            return false
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return false }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            var mappings: [CloudObjectMapping] = []
            var movedPrefixes: [(source: String, destination: String)] = []
            var selection = Set<String>()
            if mode == .copy {
                let planned = payload.objectKeys.map {
                    CloudObjectOperation.copyDestination(
                        source: $0,
                        destinationPrefix: destinationPrefix,
                        isFolder: false,
                        reserved: []
                    )
                } + payload.folderPrefixes.map {
                    CloudObjectOperation.copyDestination(
                        source: $0,
                        destinationPrefix: destinationPrefix,
                        isFolder: true,
                        reserved: []
                    )
                }
                var reserved = try await existingKeys(among: planned, client: client)
                for sourceKey in payload.objectKeys {
                    let destination = CloudObjectOperation.copyDestination(
                        source: sourceKey,
                        destinationPrefix: destinationPrefix,
                        isFolder: false,
                        reserved: reserved
                    )
                    reserved.insert(destination)
                    mappings.append(CloudObjectMapping(sourceKey: sourceKey, destinationKey: destination))
                    selection.insert(destination)
                }
                for sourcePrefix in payload.folderPrefixes {
                    let destination = CloudObjectOperation.copyDestination(
                        source: sourcePrefix,
                        destinationPrefix: destinationPrefix,
                        isFolder: true,
                        reserved: reserved
                    )
                    reserved.insert(destination)
                    mappings.append(contentsOf: try await client.prefixMappings(
                        from: sourcePrefix,
                        to: destination
                    ))
                    movedPrefixes.append((sourcePrefix, destination))
                    selection.insert(destination)
                }
            } else {
                // Moving an item that is already at the destination would make
                // CloudObjectOperation.validate throw for the whole batch, so
                // skip those and move only what actually changes place.
                mappings = payload.objectKeys.compactMap { sourceKey in
                    let destination = PathTemplate.join(
                        destinationPrefix,
                        key: PathTemplate.lastComponent(sourceKey)
                    )
                    guard destination != sourceKey else { return nil }
                    return CloudObjectMapping(sourceKey: sourceKey, destinationKey: destination)
                }
                selection = Set(mappings.map(\.destinationKey))
                for sourcePrefix in payload.folderPrefixes {
                    let destination = PathTemplate.join(
                        destinationPrefix,
                        key: PathTemplate.lastComponent(sourcePrefix)
                    ) + "/"
                    guard destination != sourcePrefix else { continue }
                    mappings.append(contentsOf: try await client.prefixMappings(
                        from: sourcePrefix,
                        to: destination
                    ))
                    movedPrefixes.append((sourcePrefix, destination))
                    selection.insert(destination)
                }
                guard !mappings.isEmpty else {
                    present("项目已经在这个位置")
                    return false
                }
            }

            try await client.performCloudOperation(mappings, mode: mode)
            noteBucketMutated()
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
            if mode == .move {
                lastDeleteUndoOperation = nil
                lastCloudUndoOperation = CloudUndoOperation(
                    accountID: accountID,
                    bucketName: bucketName,
                    title: "撤销移动",
                    mappings: mappings,
                    favoriteMoves: movedPrefixes.map {
                        CloudFavoriteMove(
                            sourcePrefix: $0.source,
                            destinationPrefix: $0.destination
                        )
                    },
                    sourceSelection: Set(payload.objectKeys + payload.folderPrefixes),
                    destinationSelection: selection
                )
            }
            present(
                mode == .move ? "已移动 \(count) 项" : "已复制 \(count) 项",
                action: mode == .move ? .undoCloudOperation : nil
            )
            return true
        } catch CloudObjectOperationError.sourceCleanupFailed {
            // A move copies first and deletes second, so it can partially
            // succeed. Refresh so the browser shows what actually happened.
            await refreshListing()
            present("目标已复制完成，但未能删除部分原文件", error: true)
            return false
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
    }

    private func prepareCrossBucketOperation(
        _ payload: CloudDragPayload,
        to destinationPrefix: String,
        mode: CloudOperationMode
    ) async {
        guard let sourceAccount = accounts.first(where: { $0.id == payload.accountID }),
              let destinationAccount = selectedAccount,
              let destinationBucket = selectedBucket,
              let destinationClient = makeClient()
        else {
            present("来源账号已不可用，无法继续", error: true)
            return
        }
        let sourceRegion = payload.sourceRegionID ?? sourceAccount.regionID
        // Resolve the source bucket from the SOURCE account. Using the
        // destination account's bucket list could pick a same-named bucket in
        // a different region and route the source client to the wrong endpoint.
        let sourceBucket: OSSBucket?
        if sourceAccount.id == selectedAccountID {
            sourceBucket = buckets.first(where: { $0.name == payload.bucketName })
        } else {
            sourceBucket = try? await clientProvider(sourceAccount, nil)
                .listBuckets()
                .first(where: { $0.name == payload.bucketName })
        }
        let resolvedSourceBucket = sourceBucket ?? OSSBucket(
            name: payload.bucketName,
            regionID: sourceRegion,
            location: sourceRegion,
            extranetEndpoint: "",
            createdAt: nil
        )
        let sourceClient: OSSClient
        do {
            sourceClient = try clientProvider(sourceAccount, resolvedSourceBucket)
        } catch {
            present(error.localizedDescription, error: true)
            return
        }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            var folders: [String: [OSSObject]] = [:]
            for prefix in payload.folderPrefixes {
                let listing = try await sourceClient.listAllObjects(prefix: prefix)
                guard !listing.truncated else { throw CloudObjectOperationError.incompleteListing }
                folders[prefix] = listing.objects
            }
            var plan = try CrossBucketOperation.plan(
                sourceAccountID: sourceAccount.id,
                destinationAccountID: destinationAccount.id,
                sourceRegion: resolvedSourceBucket.regionID,
                destinationRegion: destinationBucket.regionID,
                destinationPrefix: destinationPrefix,
                objectKeys: payload.objectKeys,
                folders: folders
            )
            for index in plan.mappings.indices where plan.mappings[index].expectedSize == 0 {
                plan.mappings[index].expectedSize = try await sourceClient.head(
                    key: plan.mappings[index].sourceKey
                ).contentLength ?? 0
            }
            plan.knownBytes = plan.mappings.reduce(0) { partial, mapping in
                let (sum, overflow) = partial.addingReportingOverflow(max(0, mapping.expectedSize))
                return overflow ? Int64.max : sum
            }

            var renamed = 0
            var filtered: [CrossBucketMapping] = []
            var reserved = Set(plan.mappings.map { $0.destinationKey })
            for var mapping in plan.mappings {
                let exists = try await destinationClient.objectExists(key: mapping.destinationKey)
                guard exists else { filtered.append(mapping); continue }
                switch settings.transferConflictPolicy {
                case .skip:
                    continue
                case .replace:
                    filtered.append(mapping)
                case .ask, .keepBoth:
                    var candidate = TransferConflictPlanner.availableKey(
                        for: mapping.destinationKey,
                        existing: reserved
                    )
                    while try await destinationClient.objectExists(key: candidate) {
                        reserved.insert(candidate)
                        candidate = TransferConflictPlanner.availableKey(
                            for: mapping.destinationKey,
                            existing: reserved
                        )
                    }
                    mapping.destinationKey = candidate
                    reserved.insert(candidate)
                    renamed += 1
                    filtered.append(mapping)
                }
            }
            let hadMappings = !plan.mappings.isEmpty
            plan.mappings = filtered
            guard !filtered.isEmpty else {
                present(CrossBucketOperation.emptyResultMessage(hadMappings: hadMappings))
                return
            }
            crossBucketPreflight = CrossBucketPreflight(
                plan: plan,
                mode: mode,
                sourceAccount: sourceAccount,
                sourceBucket: resolvedSourceBucket,
                destinationAccount: destinationAccount,
                destinationBucket: destinationBucket,
                sourceClient: sourceClient,
                destinationClient: destinationClient,
                overwrite: settings.transferConflictPolicy == .replace,
                renamedConflicts: renamed
            )
            showCrossBucketPreflight = true
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func confirmCrossBucketOperation() {
        guard let preflight = crossBucketPreflight else { return }
        crossBucketPreflight = nil
        Task { await executeCrossBucketOperation(preflight) }
    }

    private func executeCrossBucketOperation(_ preflight: CrossBucketPreflight) async {
        guard !isOrganizingCloud else { return }
        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        var copied: [CrossBucketMapping] = []
        var destinationVersions: [String: String] = [:]
        var removedSources: Set<String> = []
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "Lumen-CrossBucket-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        do {
            if preflight.plan.method == .relay {
                try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            }
            for mapping in preflight.plan.mappings {
                try Task.checkCancellation()
                if preflight.plan.method == .serverSide {
                    let versionID = try await preflight.destinationClient.copyObject(
                        fromBucket: preflight.sourceBucket.name,
                        sourceKey: mapping.sourceKey,
                        to: mapping.destinationKey,
                        overwrite: preflight.overwrite
                    )
                    if let versionID, !versionID.isEmpty {
                        destinationVersions[mapping.destinationKey] = versionID
                    }
                } else {
                    let local = temporaryRoot.appending(path: UUID().uuidString)
                    let head = try await preflight.sourceClient.head(key: mapping.sourceKey)
                    _ = try await preflight.sourceClient.downloadResumable(
                        key: mapping.sourceKey,
                        to: local,
                        within: temporaryRoot,
                        expectedSize: head.contentLength ?? mapping.expectedSize,
                        speedLimit: settings.downloadSpeedLimit
                    )
                    _ = try await preflight.destinationClient.putObject(
                        key: mapping.destinationKey,
                        fileURL: local,
                        contentType: head.contentType ?? "application/octet-stream",
                        acl: preflight.destinationAccount.defaultACL,
                        overwrite: preflight.overwrite,
                        speedLimit: settings.uploadSpeedLimit
                    )
                    if let versionID = try? await preflight.destinationClient.head(key: mapping.destinationKey).versionID,
                       !versionID.isEmpty {
                        destinationVersions[mapping.destinationKey] = versionID
                    }
                    if let tags = try? await preflight.sourceClient.getObjectTags(key: mapping.sourceKey), !tags.isEmpty {
                        try await preflight.destinationClient.putObjectTags(key: mapping.destinationKey, tags: tags)
                    }
                    try? FileManager.default.removeItem(at: local)
                }
                copied.append(mapping)
            }
            if preflight.mode == .move {
                for mapping in preflight.plan.mappings {
                    _ = try await preflight.sourceClient.deleteObject(key: mapping.sourceKey)
                    removedSources.insert(mapping.sourceKey)
                }
            }
            noteBucketMutated(
                accountID: preflight.sourceAccount.id,
                bucketName: preflight.sourceBucket.name
            )
            noteBucketMutated(
                accountID: preflight.destinationAccount.id,
                bucketName: preflight.destinationBucket.name
            )
            await refreshListing()
            if preflight.mode == .move {
                clearCloudClipboard()
            }
            present(preflight.mode == .move ? "已移动 \(copied.count) 个对象" : "已复制 \(copied.count) 个对象")
        } catch {
            for mapping in CrossBucketOperation.rollbackDestinations(
                copied: copied,
                removedSources: removedSources
            ) {
                _ = try? await preflight.destinationClient.deleteObject(
                    key: mapping.destinationKey,
                    versionID: destinationVersions[mapping.destinationKey]
                )
            }
            noteBucketMutated(
                accountID: preflight.sourceAccount.id,
                bucketName: preflight.sourceBucket.name
            )
            noteBucketMutated(
                accountID: preflight.destinationAccount.id,
                bucketName: preflight.destinationBucket.name
            )
            present("跨 Bucket 操作未完成：\(error.localizedDescription)", error: true)
        }
    }

    func undoLastCloudOperation() async {
        guard !isOrganizingCloud, let client = makeClient() else { return }

        if let deletion = lastDeleteUndoOperation,
           isCurrentScope(for: deletion) {
            isOrganizingCloud = true
            defer { isOrganizingCloud = false }
            do {
                for marker in deletion.markers.reversed() {
                    try await client.deleteObject(
                        key: marker.key,
                        versionID: marker.versionID
                    )
                }
                lastDeleteUndoOperation = nil
                noteBucketMutated()
                browser.clearSelection()
                await refreshListing()
                browser.replaceSelection(deletion.sourceSelection)
                present("已恢复删除的项目")
            } catch {
                present(error.localizedDescription, error: true)
            }
            return
        }

        guard let operation = lastCloudUndoOperation,
              isCurrentScope(for: operation)
        else { return }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            try await client.performCloudOperation(
                operation.inverseMappings,
                mode: .move
            )
            for move in operation.inverseFavoriteMoves {
                favorites.replacePrefix(
                    accountID: operation.accountID,
                    bucketName: operation.bucketName,
                    source: move.sourcePrefix,
                    destination: move.destinationPrefix
                )
            }
            lastCloudUndoOperation = nil
            noteBucketMutated()
            browser.clearSelection()
            await refreshListing()
            browser.replaceSelection(operation.sourceSelection)
            present("已撤销上一步操作")
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    private func isCurrentScope(for operation: CloudUndoOperation) -> Bool {
        selectedAccountID == operation.accountID
            && selectedBucketName == operation.bucketName
    }

    private func isCurrentScope(for operation: CloudDeleteUndoOperation) -> Bool {
        selectedAccountID == operation.accountID
            && selectedBucketName == operation.bucketName
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
        if settings.downloadLocation == .downloads {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "存储"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func startDownloads(
        objects: [OSSObject],
        folders: [OSSFolder],
        to dest: URL,
        extraPrefix: (prefix: String, folderName: String)? = nil
    ) async {
        guard let account = selectedAccount,
              let bucket = selectedBucket,
              let client = makeClient() else { return }
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
            items.append((object: object, destination: url))
        }
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
                if listing.truncated {
                    present("“\(folderName)”没有完整列出，已取消下载，以免遗漏", error: true)
                    return
                }
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
                    items.append((object: object, destination: url))
                }
            } catch {
                present(error.localizedDescription, error: true)
                return
            }
        }
        guard !items.isEmpty else {
            if skippedUnsafe > 0 {
                present("对象路径不安全，已跳过 \(skippedUnsafe) 项", error: true)
            }
            return
        }
        guard let resolved = resolveDownloadConflicts(items: items, root: dest) else {
            return
        }
        items = resolved.items
        skippedLocal += resolved.skipped
        guard !items.isEmpty else {
            present("本地已有同名文件，已跳过 \(skippedLocal) 项")
            return
        }
        transfers.downloadConcurrency = settings.concurrentDownloads
        transfers.downloadSpeedLimit = settings.downloadSpeedLimit
        transfers.enqueueDownloadJobs(
            items: items,
            client: client,
            account: account,
            bucket: bucket,
            scopedRoot: dest,
            speedLimit: settings.downloadSpeedLimit,
            allowOverwrite: resolved.allowOverwrite
        )
        if skippedLocal + skippedUnsafe > 0 {
            present("已加入 \(items.count) 个下载，跳过 \(skippedLocal + skippedUnsafe) 项")
        } else if items.count > 1 {
            present("已加入 \(items.count) 个下载")
        }
    }

    private func resolveDownloadConflicts(
        items: [(object: OSSObject, destination: URL)],
        root: URL
    ) -> (items: [(object: OSSObject, destination: URL)], skipped: Int, allowOverwrite: Bool)? {
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relativePaths = items.map { item -> String in
            let path = item.destination.standardizedFileURL.path
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : item.object.name
        }
        let existing = Set(zip(relativePaths, items).compactMap { relative, item in
            FileManager.default.fileExists(atPath: item.destination.path) ? relative : nil
        })
        var policy = settings.transferConflictPolicy
        if policy == .ask, !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "本地已有同名文件" : "本地已有 \(existing.count) 个同名文件"
            alert.informativeText = "可以替换现有文件，或跳过这些项目。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "跳过")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: policy = .replace
            case .alertSecondButtonReturn: policy = .skip
            default: return nil
            }
        }
        let resolutions = TransferConflictPlanner.plan(
            keys: relativePaths,
            existing: existing,
            policy: policy
        )
        var resolved: [(object: OSSObject, destination: URL)] = []
        var skipped = 0
        for (index, resolution) in resolutions.enumerated() {
            let item = items[index]
            switch resolution {
            case .skip, .ask:
                skipped += 1
            case .renamed(let relative):
                guard let destination = try? FileSafety.destination(root: root, relativePath: relative) else {
                    skipped += 1
                    continue
                }
                resolved.append((item.object, destination))
            case .useOriginal:
                resolved.append(item)
            }
        }
        return (resolved, skipped, policy == .replace)
    }

    func copyURLs(style: LinkStyle = .plain) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        let client = account.prefersSignedLinks ? makeClient() : nil
        var usedSigned = false
        let urls = browser.selectedObjects.compactMap { object -> String? in
            let resolved: URL?
            if let client,
               let signed = client.presignedURL(
                   key: object.key,
                   expires: settings.signedLinkLifetime.rawValue
               ) {
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
        present(usedSigned ? "已复制签名链接，\(settings.signedLinkLifetime.title)内有效" : "已复制 \(urls.count) 条链接")
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
        let objects = browser.selectedObjects
        if let object = objects.first, objects.count == 1 {
            await quickLook(object)
            return
        }
        // Space with only a single folder selected opens it (folders have no
        // QuickLook payload); this matches the double-click behavior in both
        // grid and list views.
        let folders = browser.selectedFolders
        if objects.isEmpty, folders.count == 1, let folder = folders.first {
            openFolder(folder)
        }
    }

    func quickLook(_ object: OSSObject) async {
        guard let client = makeClient() else { return }
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

    func present(
        _ text: String,
        error: Bool = false,
        action: BannerAction? = nil
    ) {
        banner = BannerMessage(text: text, isError: error, action: action)
    }

    func pasteFromClipboard(to prefix: String? = nil) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            upload(urls: urls, to: prefix)
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
                upload(urls: files, to: prefix, ownedTemporaryURLs: Set(files))
            }
        }
    }

    private var hasFileURLsOnPasteboard: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
            || NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private static func writeTemporaryJPEG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    private static func defaultClient(account: OSSAccount, bucket: OSSBucket?) throws -> OSSClient {
        let credentials = try AccountStore.credentials(for: account)
        return OSSClient(
            credentials: credentials,
            region: account.signingRegion(for: bucket),
            endpointHost: account.apiHost(for: bucket),
            bucket: bucket?.name
        )
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
        searchController.clear()
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

    var isReadyToSave: Bool {
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            defaultACL: .default,
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

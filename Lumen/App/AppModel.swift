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
    static let shared = AppModel()

    var accounts: [OSSAccount] = []
    var selectedAccountID: OSSAccount.ID?
    var buckets: [OSSBucket] = []
    var selectedBucketName: String?
    var browser = BrowserModel()
    var transfers = TransferEngine()
    var settings = AppSettings()

    var showInspector = false
    var showAccountSheet = false
    var editingAccount: OSSAccount?
    var isLoadingBuckets = false
    var banner: BannerMessage?
    var previewItem: URL?
    var inspectorHead: ObjectHead?
    var inspectorText: String?
    var isLoadingHead = false
    var showMenuBarExtra = false
    var wantsDeleteConfirmation = false
    var wantsNewFolder = false
    var pendingOpenURLs: [URL] = []
    private var didBootstrap = false
    private var listingRefreshTask: Task<Void, Never>?

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

    init() {
        accounts = AccountStore.load()
        if let stored = UUID(uuidString: lastAccountID), accounts.contains(where: { $0.id == stored }) {
            selectedAccountID = stored
        } else {
            selectedAccountID = accounts.first?.id
        }
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        browser.imagesOnly = settings.imagesOnly
        transfers.onUploadFinished = { [weak self] in
            self?.scheduleListingRefresh()
        }
        if selectedAccount != nil {
            Task { await refreshBuckets(selecting: lastBucketName.isEmpty ? nil : lastBucketName) }
        }
    }

    func selectAccount(_ account: OSSAccount) {
        selectedAccountID = account.id
        lastAccountID = account.id.uuidString
        selectedBucketName = nil
        buckets = []
        browser.reset()
        Task { await refreshBuckets() }
    }

    func selectBucket(_ bucket: OSSBucket) {
        selectedBucketName = bucket.name
        lastBucketName = bucket.name
        browser.navigate(to: "", record: false)
        browser.backStack = []
        browser.forwardStack = []
        Task { await refreshListing() }
    }

    func openFolder(_ folder: OSSFolder) {
        browser.navigate(to: folder.prefix)
        Task { await refreshListing() }
    }

    func goToPrefix(_ prefix: String) {
        browser.navigate(to: prefix)
        Task { await refreshListing() }
    }

    func goBack() {
        guard browser.goBack() else { return }
        Task { await refreshListing() }
    }

    func goForward() {
        guard browser.goForward() else { return }
        Task { await refreshListing() }
    }

    func refreshListing() async {
        guard let client = makeClient() else { return }
        browser.isLoading = true
        browser.errorMessage = nil
        do {
            let listing = try await client.listAll(prefix: browser.prefix)
            browser.apply(listing, imagesOnly: settings.imagesOnly)
            if listing.isTruncated {
                present("这个文件夹里的对象很多，只加载了前几页")
            }
        } catch is CancellationError {
            // Ignore.
        } catch {
            browser.errorMessage = error.localizedDescription
        }
        browser.isLoading = false
    }

    func refreshBuckets(selecting preferred: String? = nil) async {
        guard let account = selectedAccount else { return }
        isLoadingBuckets = true
        defer { isLoadingBuckets = false }
        do {
            let creds = try AccountStore.credentials(for: account)
            let client = OSSClient(
                credentials: creds,
                region: account.regionID,
                endpointHost: account.apiHost(for: nil),
                bucket: nil
            )
            let list = try await client.listBuckets()
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
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func makeClient() -> OSSClient? {
        guard let account = selectedAccount else { return nil }
        do {
            let creds = try AccountStore.credentials(for: account)
            var client = OSSClient(
                credentials: creds,
                region: account.signingRegion(for: selectedBucket),
                endpointHost: account.apiHost(for: selectedBucket),
                bucket: selectedBucket?.name
            )
            if let bucket = selectedBucket {
                client = client.scoped(to: bucket, account: account)
            }
            return client
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
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        AccountStore.save(accounts)
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
        accounts.removeAll { $0.id == account.id }
        AccountStore.deleteSecrets(id: account.id)
        AccountStore.save(accounts)
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
            buckets = []
            selectedBucketName = nil
            browser.reset()
            if selectedAccount != nil {
                Task { await refreshBuckets() }
            }
        }
    }

    func upload(urls: [URL]) {
        guard let client = makeClient(), let account = selectedAccount else {
            pendingOpenURLs.append(contentsOf: urls)
            showAccountSheet = accounts.isEmpty
            present("先添加账号并选择存储空间", error: true)
            return
        }
        let skipped = transfers.enqueueUploads(
            urls: urls,
            client: client,
            account: account,
            bucket: selectedBucket,
            prefix: browser.prefix,
            settings: settings
        )
        if skipped > 0 {
            present("已跳过 \(skipped) 个不支持的文件")
        }
        scheduleListingRefresh()
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
                    let listing = try await client.listAll(prefix: key)
                    for object in listing.objects {
                        try await client.deleteObject(key: object.key)
                    }
                    try? await client.deleteObject(key: key)
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
            let listing = try await client.listAll(prefix: folder.prefix)
            for object in listing.objects {
                try await client.deleteObject(key: object.key)
            }
            try? await client.deleteObject(key: folder.prefix)
            await refreshListing()
        } catch {
            present(error.localizedDescription, error: true)
        }
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
        guard let client = makeClient() else { return }
        let objects = browser.selectedObjects
        guard !objects.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "存储"
        panel.message = "选择下载位置"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        transfers.enqueueDownloads(objects: objects, client: client, folder: folder)
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
            case .markdown: return "![\(object.name)](\(url.absoluteString))"
            case .html: return "<img src=\"\(url.absoluteString)\" alt=\"\(object.name)\" />"
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
            inspectorHead = nil
            inspectorText = nil
            return
        }
        isLoadingHead = true
        defer { isLoadingHead = false }
        inspectorText = nil
        do {
            inspectorHead = try await client.head(key: object.key)
        } catch {
            inspectorHead = nil
        }
        guard object.isText, object.size <= 512_000 else { return }
        if let data = try? await client.objectData(key: object.key),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            inspectorText = text
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
}

enum LinkStyle {
    case plain, markdown, html
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
            prefixTemplate: "assets/{yyyy}/{MM}/{dd}/",
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

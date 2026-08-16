import AppKit
import Foundation
import Testing
@testable import Lumen

@MainActor
struct AppModelTests {
    @Test func ordinaryBannerUsesShortDisplayDurationWithoutAnAction() {
        let banner = BannerMessage(text: "已复制链接", isError: false)

        #expect(banner.action == nil)
        #expect(banner.displayDuration == .milliseconds(2_400))
    }

    @Test func undoBannerUsesLongDisplayDurationAndSemanticAction() {
        let banner = BannerMessage(
            text: "已重命名“封面.png”",
            isError: false,
            action: .undoCloudOperation
        )

        #expect(banner.action == .undoCloudOperation)
        #expect(banner.displayDuration == .milliseconds(5_500))
    }

    @Test func presentingUndoFeedbackPreservesTheSemanticAction() {
        let model = AppModel(kind: .settings, services: AppServices(accounts: []))

        model.present("已移动 2 项", action: .undoCloudOperation)

        #expect(model.banner?.text == "已移动 2 项")
        #expect(model.banner?.isError == false)
        #expect(model.banner?.action == .undoCloudOperation)
    }

    @Test func preferredBrowserViewPersists() {
        let defaults = Self.defaults()
        let first = AppSettings(defaults: defaults)

        first.preferredViewMode = .list

        #expect(AppSettings(defaults: defaults).preferredViewMode == .list)
    }

    @Test func newWindowUsesPreferredBrowserView() {
        let defaults = Self.defaults()
        let settings = AppSettings(defaults: defaults)
        settings.preferredViewMode = .list
        let services = AppServices(accounts: [], settings: settings)

        let model = AppModel(services: services)

        #expect(model.browser.viewMode == .list)
    }

    @Test func informationIsAvailableOnlyInsideABucket() {
        let model = AppModel(kind: .settings, services: AppServices(accounts: []))

        #expect(!model.canShowInformation)

        let bucket = OSSBucket(
            name: "design-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name

        #expect(model.canShowInformation)
    }

    @Test func applyingPreferredViewUpdatesEveryOpenWindow() {
        let defaults = Self.defaults()
        let services = AppServices(accounts: [], settings: AppSettings(defaults: defaults))
        let first = AppModel(services: services)
        let second = AppModel(services: services)
        let settings = AppModel(kind: .settings, services: services)

        settings.applyPreferredViewModeToAllSessions(.list)

        #expect(first.browser.viewMode == .list)
        #expect(second.browser.viewMode == .list)
        #expect(settings.settings.preferredViewMode == .list)
    }

    @Test func testingAnAccountDoesNotChangeTheCurrentSelection() async throws {
        let account = OSSAccount(
            id: UUID(),
            name: "Studio",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let transport = AccountTestTransport()
        let services = AppServices(accounts: [account])
        let model = AppModel(kind: .settings, services: services) { _, _ in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: nil,
                transport: transport
            )
        }
        model.selectedAccountID = nil

        let bucketCount = try await model.testAccount(account)

        #expect(bucketCount == 2)
        #expect(model.selectedAccountID == nil)
    }

    @Test func bucketSearchUsesTheSelectedAccountAndBucket() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.searchText = "hero"
        model.searchScope = .bucket

        await model.runBucketSearch()

        #expect(model.searchController.activeQuery?.accountID == account.id)
        #expect(model.searchController.activeQuery?.bucketName == bucket.name)
        #expect(model.searchController.results.map(\.key) == ["art/hero.png"])
    }

    @Test func openingSearchResultNavigatesToItsFolderAndSelectsIt() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        let object = OSSObject(
            key: "art/hero.png",
            size: 42,
            etag: "hero",
            lastModified: nil,
            storageClass: "Standard"
        )

        await model.openSearchResult(object)

        #expect(model.browser.prefix == "art/")
        #expect(model.browser.selectedKeys == [object.key])
    }

    @Test func changingBucketClearsBucketSearchResults() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.searchText = "hero"
        model.searchScope = .bucket
        await model.runBucketSearch()

        model.selectBucket(
            OSSBucket(
                name: "archive",
                regionID: bucket.regionID,
                location: bucket.location,
                extranetEndpoint: bucket.extranetEndpoint,
                createdAt: nil
            )
        )

        #expect(model.searchController.results.isEmpty)
        #expect(model.searchController.activeQuery == nil)
    }

    @Test func clickingTheSelectedBucketAtRootDoesNotResetNavigation() {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.prefix = ""
        model.browser.backStack = ["art/"]

        model.applySidebarSelection(.bucket(bucket.name))

        #expect(model.selectedBucketName == bucket.name)
        #expect(model.browser.prefix == "")
        #expect(model.browser.backStack == ["art/"])
    }

    @Test func clickingTheCurrentBucketFromASubfolderReturnsToRoot() {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.prefix = "art/"
        model.browser.backStack = [""]

        model.applySidebarSelection(.bucket(bucket.name))

        #expect(model.selectedBucketName == bucket.name)
        #expect(model.browser.prefix == "")
        #expect(model.browser.backStack.isEmpty)
    }

    @Test func copySelectionMakesPasteAvailable() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.replaceSelection(["cover.png"])

        #expect(model.canCopyCloudItems)

        model.copyCloudSelection()

        #expect(model.cloudClipboard?.objectKeys == ["cover.png"])
        #expect(model.cloudClipboard?.bucketName == bucket.name)
        #expect(model.banner?.text.contains("已复制") == true)
    }

    @Test func copyWithoutSelectionDoesNotCreateAClipboard() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]

        model.copyCloudSelection()

        #expect(model.cloudClipboard == nil)
        #expect(!model.canCopyCloudItems)
    }

    @Test func copyClickedKeyWorksWithoutAPriorSelection() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.folders = [OSSFolder(prefix: "art/")]
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]

        model.copyCloudSelection(clickedKey: "art/")

        #expect(model.cloudClipboard?.folderPrefixes == ["art/"])
        #expect(model.canPasteCloudItems)
        #expect(model.canPaste)
    }

    @Test func copyPasteInTheSameFolderKeepsBothNames() {
        #expect(
            CloudObjectOperation.copyDestination(
                source: "cover.png",
                destinationPrefix: "",
                isFolder: false,
                reserved: []
            ) == "cover 2.png"
        )
        #expect(
            CloudObjectOperation.copyDestination(
                source: "art/",
                destinationPrefix: "",
                isFolder: true,
                reserved: []
            ) == "art 2/"
        )
        #expect(
            CloudObjectOperation.copyDestination(
                source: "cover.png",
                destinationPrefix: "art/",
                isFolder: false,
                reserved: []
            ) == "art/cover.png"
        )
        #expect(
            CloudObjectOperation.copyDestination(
                source: "cover.png",
                destinationPrefix: "art/",
                isFolder: false,
                reserved: ["art/cover.png"]
            ) == "art/cover 2.png"
        )
    }

    @Test func cloudClipboardRoundTripsThroughPasteboard() {
        let payload = CloudDragPayload(
            accountID: UUID(),
            bucketName: "design-assets",
            sourceRegionID: "cn-hangzhou",
            objectKeys: ["cover.png"],
            folderPrefixes: ["art/"]
        )
        let board = NSPasteboard.withUniqueName()

        CloudClipboard.write(payload, mode: .move, to: board)

        #expect(CloudClipboard.read(from: board)?.payload == payload)
        #expect(CloudClipboard.read(from: board)?.mode == .move)
    }

    @Test func cutSelectionUsesMoveOnPaste() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.replaceSelection(["cover.png"])

        model.cutCloudSelection()

        #expect(model.cloudClipboard?.objectKeys == ["cover.png"])
        #expect(model.cloudClipboardMode == .move)
        #expect(model.pasteMenuTitle == "移动到此处")
        #expect(model.banner?.text.contains("已剪切") == true)
    }

    @Test func moveStaysInPlaceWhenPastingIntoTheSameFolder() {
        #expect(
            CloudObjectOperation.staysInPlace(
                objectKeys: ["cover.png"],
                folderPrefixes: [],
                destinationPrefix: ""
            )
        )
        #expect(
            !CloudObjectOperation.staysInPlace(
                objectKeys: ["cover.png"],
                folderPrefixes: [],
                destinationPrefix: "art/"
            )
        )
    }

    @Test func folderDeleteUsesClickedKeyEvenIfSelectionClears() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.folders = [OSSFolder(prefix: "art/")]
        model.browser.replaceSelection(["art/"])

        model.requestDeleteSelection(keys: ["art/"])
        model.browser.clearSelection()

        #expect(model.wantsDeleteConfirmation)
        #expect(model.deleteDialogTitle.contains("art"))
    }

    @Test func organizingCloudBlocksDeleteConfirmation() {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.objects = [
            OSSObject(key: "a.txt", size: 1, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.imagesOnly = false
        model.browser.replaceSelection(["a.txt"])
        model.isOrganizingCloud = true

        model.requestDeleteSelection()

        #expect(model.wantsDeleteConfirmation == false)
        #expect(model.banner?.isError == true)
    }

    @Test func incompleteFolderListingNeverEnqueuesDownloads() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = TruncatedListTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        let folder = OSSFolder(prefix: "huge/")
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "lumen-download-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        await model.startDownloads(objects: [], folders: [folder], to: dest)

        #expect(model.transfers.jobs.isEmpty)
        #expect(model.banner?.text.contains("没有完整列出") == true)
        #expect(model.banner?.isError == true)
    }

    @Test func mutatingTheBucketClearsStaleSearchResults() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.searchText = "hero"
        model.searchScope = .bucket
        await model.runBucketSearch()

        #expect(model.searchController.results.map(\.key) == ["art/hero.png"])

        model.noteBucketMutated()

        #expect(model.searchController.results.isEmpty)
        #expect(model.searchController.activeQuery == nil)
    }

    @Test func inlineRenameUndoNeverFallsThroughToCloudUndo() {
        #expect(WorkspaceUndo.resolve(isRenaming: true, fieldCanUndo: true) == .field)
        #expect(WorkspaceUndo.resolve(isRenaming: true, fieldCanUndo: false) == .cancelRename)
        #expect(WorkspaceUndo.resolve(isRenaming: false, fieldCanUndo: false) == .cloud)
    }

    @Test func quitPromptsWhenOrganizingOrTransferring() {
        #expect(!AppTermination.shouldConfirm(transferring: false, organizing: false))
        #expect(AppTermination.shouldConfirm(transferring: true, organizing: false))
        #expect(AppTermination.shouldConfirm(transferring: false, organizing: true))
        #expect(AppTermination.prompt(transferring: false, organizing: true).title == "还有云端整理未完成")
    }

    @Test func existingKeysFallsBackToHeadWhenAParentListingIsTruncated() async throws {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = ConflictProbeTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        let keys = (1...41).map { "file-\($0).txt" }

        let found = try await model.existingKeys(among: keys, client: model.makeClient()!)

        #expect(found == ["file-1.txt"])
        #expect(await transport.headCount == 41)
    }

    private static func defaults() -> UserDefaults {
        let suite = "Lumen.AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func account() -> OSSAccount {
        OSSAccount(
            id: UUID(),
            name: "Studio",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
    }

    private static func bucket() -> OSSBucket {
        OSSBucket(
            name: "design-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
    }

    private static func model(
        account: OSSAccount,
        bucket: OSSBucket,
        transport: any OSSHTTPTransport
    ) -> AppModel {
        let model = AppModel(kind: .settings, services: AppServices(accounts: [account])) { _, _ in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: bucket.regionID,
                endpointHost: bucket.extranetEndpoint,
                bucket: bucket.name,
                transport: transport
            )
        }
        model.selectedAccountID = account.id
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name
        return model
    }
}

private actor AccountTestTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml = """
        <ListAllMyBucketsResult><Buckets>
          <Bucket><Name>design-assets</Name><Location>oss-cn-hangzhou</Location></Bucket>
          <Bucket><Name>website</Name><Location>oss-cn-shanghai</Location></Bucket>
        </Buckets></ListAllMyBucketsResult>
        """
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(xml.utf8),
            temporaryDownloadURL: nil
        )
    }
}

private actor TruncatedListTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml = """
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <Contents>
            <Key>huge/a.txt</Key><Size>1</Size><ETag>a</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """
        return OSSHTTPResult(status: 200, headers: [:], data: Data(xml.utf8), temporaryDownloadURL: nil)
    }
}

private actor ConflictProbeTransport: OSSHTTPTransport {
    private(set) var headCount = 0

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.httpMethod == "GET" {
            let xml = """
            <ListBucketResult>
              <IsTruncated>true</IsTruncated>
              <Contents>
                <Key>file-1.txt</Key><Size>1</Size><ETag>a</ETag><StorageClass>Standard</StorageClass>
              </Contents>
            </ListBucketResult>
            """
            return OSSHTTPResult(status: 200, headers: [:], data: Data(xml.utf8), temporaryDownloadURL: nil)
        }
        headCount += 1
        if request.url?.path.hasSuffix("/file-1.txt") == true {
            return OSSHTTPResult(status: 200, headers: [:], data: Data(), temporaryDownloadURL: nil)
        }
        return OSSHTTPResult(
            status: 404,
            headers: [:],
            data: Data("<Error><Code>NoSuchKey</Code><Message>missing</Message></Error>".utf8),
            temporaryDownloadURL: nil
        )
    }
}

private actor BrowserSearchTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>art/hero.png</Key><Size>42</Size><ETag>hero</ETag><StorageClass>Standard</StorageClass>
          </Contents>
          <Contents>
            <Key>notes/readme.txt</Key><Size>12</Size><ETag>readme</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(xml.utf8),
            temporaryDownloadURL: nil
        )
    }
}

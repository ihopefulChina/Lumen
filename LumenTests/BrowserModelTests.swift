import Foundation
import Testing
@testable import Lumen

@MainActor
struct BrowserModelTests {
    @Test func orderedSelectionIncludesFoldersBeforeObjects() {
        let model = Self.model()

        #expect(model.orderedVisibleKeys == ["folder/", "a.txt", "b.txt", "c.txt"])
    }

    @Test func commandSelectionTogglesWithoutLosingOtherItems() {
        let model = Self.model()

        model.select(key: "a.txt", modifiers: [])
        model.select(key: "c.txt", modifiers: [.toggle])
        #expect(model.selectedKeys == ["a.txt", "c.txt"])
        model.select(key: "a.txt", modifiers: [.toggle])
        #expect(model.selectedKeys == ["c.txt"])
    }

    @Test func shiftSelectionUsesAStableAnchorAndVisibleRange() {
        let model = Self.model()

        model.select(key: "a.txt", modifiers: [])
        model.select(key: "c.txt", modifiers: [.extendRange])

        #expect(model.selectedKeys == ["a.txt", "b.txt", "c.txt"])
        #expect(model.focusedKey == "c.txt")
    }

    @Test func primaryObjectUsesVisibleOrderEvenWhenFolderIsSelected() {
        let model = Self.model()
        model.replaceSelection(["folder/", "b.txt", "c.txt"])

        #expect(model.primarySelection?.key == "b.txt")
    }

    @Test func movingSelectionFollowsDisplayedOrder() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.moveSelection(.next, extending: false)
        #expect(model.selectedKeys == ["b.txt"])
        model.moveSelection(.previous, extending: true)
        #expect(model.selectedKeys == ["a.txt", "b.txt"])
    }

    @Test func searchRemovesHiddenSelectionFocusAndAnchor() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.searchText = "b"

        #expect(model.selectedKeys.isEmpty)
        #expect(model.focusedKey == nil)
        #expect(model.selectionAnchorKey == nil)
        #expect(model.selectedObjects.isEmpty)
    }

    @Test func searchKeepsASelectionThatRemainsVisible() {
        let model = Self.model()
        model.select(key: "b.txt", modifiers: [])

        model.searchText = "b"

        #expect(model.selectedKeys == ["b.txt"])
        #expect(model.focusedKey == "b.txt")
        #expect(model.selectionAnchorKey == "b.txt")
    }

    @Test func navigatingToAnotherFolderClearsTheFolderSearch() {
        let model = Self.model()
        model.searchText = "b"

        model.navigate(to: "folder/")

        #expect(model.searchText.isEmpty)
        #expect(model.selectedKeys.isEmpty)
    }

    @Test func mediaFilterRemovesAnUnsupportedSelection() {
        let model = Self.model()
        model.objects.append(
            OSSObject(
                key: "archive.zip",
                size: 1,
                etag: "zip",
                lastModified: nil,
                storageClass: "Standard"
            )
        )
        model.select(key: "archive.zip", modifiers: [])

        model.imagesOnly = true

        #expect(model.selectedKeys.isEmpty)
        #expect(model.focusedKey == nil)
        #expect(model.selectionAnchorKey == nil)
    }

    @Test func refreshedListingRemovesASelectionThatNoLongerExists() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.apply(
            ObjectListing(
                folders: [],
                objects: [
                    OSSObject(
                        key: "b.txt",
                        size: 1,
                        etag: "b",
                        lastModified: nil,
                        storageClass: "Standard"
                    )
                ],
                isTruncated: false,
                nextToken: nil
            ),
            imagesOnly: false
        )

        #expect(model.selectedKeys.isEmpty)
        #expect(model.focusedKey == nil)
        #expect(model.selectionAnchorKey == nil)
    }

    @Test func hiddenClickedKeyCannotCreateACloudDragPayload() {
        let services = AppServices(accounts: [])
        let app = AppModel(kind: .settings, services: services)
        app.browser.imagesOnly = false
        app.browser.objects = [
            OSSObject(
                key: "hidden.txt",
                size: 1,
                etag: "hidden",
                lastModified: nil,
                storageClass: "Standard"
            )
        ]
        app.browser.searchText = "visible"

        let payload = app.cloudDragPayload(clickedKey: "hidden.txt")

        #expect(payload.objectKeys.isEmpty)
        #expect(payload.folderPrefixes.isEmpty)
    }

    @Test func sizeSortingKeepsFoldersFirstAndUsesTheRequestedDirection() {
        let model = BrowserModel(defaults: Self.defaults())
        model.imagesOnly = false
        model.folders = [
            OSSFolder(prefix: "alpha/"),
            OSSFolder(prefix: "zulu/")
        ]
        model.objects = [
            OSSObject(key: "small.txt", size: 1, etag: "s", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "large.txt", size: 100, etag: "l", lastModified: nil, storageClass: "Standard")
        ]
        model.sortField = .size
        model.sortDirection = .descending

        #expect(model.visibleFolders.map(\.prefix) == ["zulu/", "alpha/"])
        #expect(model.visibleObjects.map(\.key) == ["large.txt", "small.txt"])
        #expect(model.orderedVisibleKeys == ["zulu/", "alpha/", "large.txt", "small.txt"])
    }

    @Test func browserSortPreferencePersistsAcrossWindows() {
        let defaults = Self.defaults()
        let first = BrowserModel(defaults: defaults)
        first.sortField = .modified
        first.sortDirection = .descending

        let reopened = BrowserModel(defaults: defaults)

        #expect(reopened.sortField == .modified)
        #expect(reopened.sortDirection == .descending)
    }

    @Test func favoriteLocationsPersistAndDoNotDuplicate() {
        let defaults = Self.defaults()
        let accountID = UUID()
        let favorite = FavoriteLocation(
            accountID: accountID,
            bucketName: "assets",
            prefix: "design/icons/",
            name: "icons"
        )
        let store = FavoriteStore(defaults: defaults)

        store.add(favorite)
        store.add(favorite)

        #expect(store.items == [favorite])
        #expect(FavoriteStore(defaults: defaults).items == [favorite])
        store.remove(favorite)
        #expect(store.items.isEmpty)
    }

    @Test func movingAFolderUpdatesNestedFavoriteLocations() {
        let defaults = Self.defaults()
        let accountID = UUID()
        let store = FavoriteStore(defaults: defaults)
        store.add(.init(
            accountID: accountID,
            bucketName: "assets",
            prefix: "old/sub/",
            name: "sub"
        ))

        store.replacePrefix(
            accountID: accountID,
            bucketName: "assets",
            source: "old/",
            destination: "new/"
        )

        #expect(store.items.first?.prefix == "new/sub/")
    }

    @Test func nativeTableSelectionKeepsAKeyboardFocusAndAnchor() {
        let model = Self.model()

        model.replaceSelection(["b.txt", "c.txt"])

        #expect(model.focusedKey == "b.txt")
        #expect(model.selectionAnchorKey == "b.txt")
        model.moveSelection(.next, extending: true)
        #expect(model.selectedKeys == ["b.txt", "c.txt"])
    }

    @Test func staleRequestContextCannotCommit() {
        let gate = BrowserRequestGate()
        let accountID = UUID()
        let stale = gate.begin(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "old/",
            objectKey: nil
        )
        let current = gate.begin(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "new/",
            objectKey: nil
        )

        #expect(!gate.canCommit(stale))
        #expect(gate.canCommit(current))
        gate.invalidate()
        #expect(!gate.canCommit(current))
    }

    @Test func staleListingResponseCannotOverwriteCurrentFolder() async throws {
        let account = OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let bucket = OSSBucket(
            name: "bucket",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        let transport = DelayedBrowserTransport()
        let services = AppServices(accounts: [account])
        let model = AppModel(kind: .window, services: services) { _, selectedBucket in
            OSSClient(
                credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: selectedBucket?.name,
                transport: transport
            )
        }
        model.selectedAccountID = account.id
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name
        model.browser.prefix = "old/"

        let staleTask = Task { await model.refreshListing() }
        try await Self.waitForRequests(1, transport: transport)
        model.browser.prefix = "new/"
        let currentTask = Task { await model.refreshListing() }
        try await Self.waitForRequests(2, transport: transport)

        await transport.resume(
            index: 1,
            data: Self.listingXML(key: "new/current.txt")
        )
        await currentTask.value
        await transport.resume(
            index: 0,
            data: Self.listingXML(key: "old/stale.txt")
        )
        await staleTask.value

        #expect(model.browser.prefix == "new/")
        #expect(model.browser.objects.map(\.key) == ["new/current.txt"])
        #expect(!model.browser.isLoading)
    }

    @Test func incomingFilesAreQueuedUntilTheFirstWindowSessionExists() {
        let services = AppServices(accounts: [])
        let incoming = URL(fileURLWithPath: "/tmp/cold-launch.png")

        services.routeIncoming([incoming])
        let model = AppModel(kind: .window, services: services)

        #expect(model.pendingOpenURLs == [incoming])
    }

    @Test func closingQuickLookDeletesItsOwnedTemporaryFile() throws {
        let services = AppServices(accounts: [])
        let model = AppModel(kind: .settings, services: services)
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "lumen-quicklook-test-\(UUID().uuidString)")
        try Data("preview".utf8).write(to: temporary)

        model.presentPreview(at: temporary)
        model.previewItem = nil

        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func invalidObjectRenameReportsFailureWithoutSendingARequest() async {
        let transport = RenameResultTransport(steps: [])
        let fixture = Self.renameModel(transport: transport)

        let succeeded = await fixture.model.rename(fixture.object, to: "nested/name")

        #expect(!succeeded)
        #expect(fixture.model.banner?.isError == true)
        #expect(await transport.requestCount == 0)
    }

    @Test func invalidFolderRenameReportsFailureWithoutSendingARequest() async {
        let transport = RenameResultTransport(steps: [])
        let fixture = Self.renameModel(transport: transport)

        let succeeded = await fixture.model.renameFolder(
            OSSFolder(prefix: "folder/"),
            to: "nested/name"
        )

        #expect(!succeeded)
        #expect(fixture.model.banner?.isError == true)
        #expect(await transport.requestCount == 0)
    }

    @Test func objectRenameConflictKeepsSourceSelectionAndEditSession() async {
        let conflict = Data(
            "<Error><Code>FileAlreadyExists</Code><Message>Exists</Message><RequestId>rename</RequestId></Error>".utf8
        )
        let transport = RenameResultTransport(steps: [
            .response(status: 409, data: conflict)
        ])
        let fixture = Self.renameModel(transport: transport)
        fixture.model.browser.replaceSelection([fixture.object.key])
        #expect(fixture.model.browser.beginRenaming())
        fixture.model.browser.updateRenameDraft("new.txt")

        let succeeded = await fixture.model.rename(fixture.object, to: "new.txt")

        #expect(!succeeded)
        #expect(fixture.model.browser.selectedKeys == [fixture.object.key])
        #expect(fixture.model.browser.renameSession?.draft == "new.txt")
        #expect(fixture.model.lastCloudUndoOperation == nil)
        #expect(await transport.methods == ["PUT"])
    }

    @Test func successfulObjectRenameReturnsSuccessAndSelectsNewKey() async {
        let listing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>new.txt</Key><Size>1</Size><ETag>new</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
        let transport = RenameResultTransport(steps: [
            .response(status: 200, data: Data()),
            .response(status: 204, data: Data()),
            .response(status: 200, data: listing)
        ])
        let fixture = Self.renameModel(transport: transport)
        fixture.model.browser.replaceSelection([fixture.object.key])

        let succeeded = await fixture.model.rename(fixture.object, to: "new.txt")

        #expect(succeeded)
        #expect(fixture.model.browser.selectedKeys == ["new.txt"])
        #expect(fixture.model.lastCloudUndoOperation == CloudUndoOperation(
            accountID: fixture.model.selectedAccountID!,
            bucketName: "bucket",
            title: "撤销重命名",
            mappings: [
                CloudObjectMapping(sourceKey: "old.txt", destinationKey: "new.txt")
            ],
            favoriteMoves: [],
            sourceSelection: ["old.txt"],
            destinationSelection: ["new.txt"]
        ))
        #expect(await transport.methods == ["PUT", "DELETE", "GET"])
    }

    @Test func successfulFolderRenameRecordsExactMappingsAndFavoriteMove() async {
        let sourceListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>folder/素材 2x.png</Key><Size>1</Size><ETag>old</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
        let refreshedListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>renamed/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """.utf8)
        let transport = RenameResultTransport(steps: [
            .response(status: 200, data: sourceListing),
            .response(status: 404, data: Data()),
            .response(status: 200, data: Data()),
            .response(status: 204, data: Data()),
            .response(status: 200, data: refreshedListing)
        ])
        let fixture = Self.renameModel(transport: transport)
        let accountID = fixture.model.selectedAccountID!
        fixture.model.browser.folders = [OSSFolder(prefix: "folder/")]
        fixture.model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "folder/nested/",
            name: "nested"
        ))

        let succeeded = await fixture.model.renameFolder(
            OSSFolder(prefix: "folder/"),
            to: "renamed"
        )

        #expect(succeeded)
        #expect(fixture.model.browser.selectedKeys == ["renamed/"])
        #expect(fixture.model.favorites.items.first?.prefix == "renamed/nested/")
        #expect(fixture.model.lastCloudUndoOperation == CloudUndoOperation(
            accountID: accountID,
            bucketName: "bucket",
            title: "撤销重命名",
            mappings: [
                CloudObjectMapping(
                    sourceKey: "folder/素材 2x.png",
                    destinationKey: "renamed/素材 2x.png"
                )
            ],
            favoriteMoves: [
                CloudFavoriteMove(sourcePrefix: "folder/", destinationPrefix: "renamed/")
            ],
            sourceSelection: ["folder/"],
            destinationSelection: ["renamed/"]
        ))
        #expect(await transport.methods == ["GET", "HEAD", "PUT", "DELETE", "GET"])
    }

    private static func model() -> BrowserModel {
        let model = BrowserModel(defaults: defaults())
        model.folders = [OSSFolder(prefix: "folder/")]
        model.objects = [
            OSSObject(key: "a.txt", size: 1, etag: "a", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "b.txt", size: 1, etag: "b", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "c.txt", size: 1, etag: "c", lastModified: nil, storageClass: "Standard")
        ]
        model.imagesOnly = false
        return model
    }

    private static func defaults() -> UserDefaults {
        let suite = "LumenTests.BrowserModel.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private static func renameModel(
        transport: RenameResultTransport
    ) -> (model: AppModel, object: OSSObject) {
        let account = OSSAccount(
            id: UUID(),
            name: "Rename Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let bucket = OSSBucket(
            name: "bucket",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        let object = OSSObject(
            key: "old.txt",
            size: 1,
            etag: "old",
            lastModified: nil,
            storageClass: "Standard"
        )
        let services = AppServices(accounts: [account])
        let model = AppModel(kind: .settings, services: services) { _, selectedBucket in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: selectedBucket?.name,
                transport: transport
            )
        }
        model.selectedAccountID = account.id
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name
        model.browser.objects = [object]
        model.browser.imagesOnly = false
        return (model, object)
    }

    private static func waitForRequests(
        _ count: Int,
        transport: DelayedBrowserTransport
    ) async throws {
        for _ in 0..<100 {
            if await transport.requestCount == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(count) requests")
    }

    private static func listingXML(key: String) -> Data {
        Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>\(key)</Key><Size>1</Size><ETag>etag</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
    }
}

private actor RenameResultTransport: OSSHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, data: Data)
    }

    private var steps: [Step]
    private(set) var methods: [String] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var requestCount: Int { methods.count }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        methods.append(request.httpMethod ?? "")
        guard !steps.isEmpty else {
            throw OSSServiceError(
                statusCode: 0,
                code: "MissingStub",
                message: "Missing rename response",
                requestId: ""
            )
        }
        switch steps.removeFirst() {
        case .response(let status, let data):
            return OSSHTTPResult(
                status: status,
                headers: [:],
                data: data,
                temporaryDownloadURL: nil
            )
        }
    }
}

private actor DelayedBrowserTransport: OSSHTTPTransport {
    private var continuations: [CheckedContinuation<OSSHTTPResult, Never>] = []

    var requestCount: Int { continuations.count }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int, data: Data) {
        continuations[index].resume(
            returning: OSSHTTPResult(
                status: 200,
                headers: [:],
                data: data,
                temporaryDownloadURL: nil
            )
        )
    }
}

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

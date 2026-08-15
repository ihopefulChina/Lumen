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
        transport: BrowserSearchTransport
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

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

    private static func defaults() -> UserDefaults {
        let suite = "Lumen.AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
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

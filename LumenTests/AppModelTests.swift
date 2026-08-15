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

    private static func defaults() -> UserDefaults {
        let suite = "Lumen.AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

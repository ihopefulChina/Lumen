import Foundation
import Testing
@testable import Lumen

@MainActor
struct UpdateServiceTests {
    @Test func updateFeedIsPinnedToTheLatestLumenReleaseAsset() {
        #expect(
            AppUpdater.feedURL.absoluteString
                == "https://github.com/ihopefulChina/Lumen/releases/latest/download/appcast.xml"
        )
    }

    @Test func automaticCheckPreferenceIsForwardedToTheUpdaterDriver() {
        let driver = RecordingUpdaterDriver()
        let updater = AppUpdater(driver: driver)

        updater.automaticallyChecksForUpdates = false

        #expect(!driver.automaticallyChecksForUpdates)
    }

    @Test func manualCheckIsForwardedExactlyOnce() {
        let driver = RecordingUpdaterDriver()
        let updater = AppUpdater(driver: driver)

        updater.checkForUpdates()

        #expect(driver.checkCount == 1)
    }
}

@MainActor
private final class RecordingUpdaterDriver: AppUpdaterDriving {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}

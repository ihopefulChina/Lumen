import AppKit
import Observation
import Sparkle

@MainActor
protocol AppUpdaterDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdaterDriver: AppUpdaterDriving {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
@Observable
final class AppUpdater {
    static let feedURL = URL(
        string: "https://ihopefulchina.github.io/Lumen/appcast.xml"
    )!

    private var storedDriver: (any AppUpdaterDriving)?

    init(driver: (any AppUpdaterDriving)? = nil) {
        storedDriver = driver
    }

    var automaticallyChecksForUpdates: Bool {
        get { driver.automaticallyChecksForUpdates }
        set { driver.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        driver.canCheckForUpdates
    }

    func checkForUpdates() {
        driver.checkForUpdates()
    }

    private var driver: any AppUpdaterDriving {
        if let storedDriver {
            return storedDriver
        }
        let driver = SparkleUpdaterDriver()
        storedDriver = driver
        return driver
    }
}

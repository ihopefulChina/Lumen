import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var concurrentUploads: Int {
        didSet { defaults.set(concurrentUploads, forKey: Keys.concurrent) }
    }
    var convertHEIC: Bool {
        didSet { defaults.set(convertHEIC, forKey: Keys.heic) }
    }
    var imagesOnly: Bool {
        didSet { defaults.set(imagesOnly, forKey: Keys.imagesOnly) }
    }
    var playCompleteSound: Bool {
        didSet { defaults.set(playCompleteSound, forKey: Keys.sound) }
    }
    var showMenuBarWhileTransferring: Bool {
        didSet { defaults.set(showMenuBarWhileTransferring, forKey: Keys.menuBar) }
    }
    var checkUpdatesAutomatically: Bool {
        didSet { defaults.set(checkUpdatesAutomatically, forKey: Keys.autoUpdate) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Keys.concurrent) as? Int
        self.concurrentUploads = min(6, max(1, stored ?? 3))
        self.convertHEIC = defaults.object(forKey: Keys.heic) as? Bool ?? false
        self.imagesOnly = defaults.object(forKey: Keys.imagesOnly) as? Bool ?? true
        self.playCompleteSound = defaults.bool(forKey: Keys.sound)
        self.showMenuBarWhileTransferring = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        self.checkUpdatesAutomatically = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
    }

    private enum Keys {
        static let concurrent = "settings.concurrentUploads"
        static let heic = "settings.convertHEIC"
        static let imagesOnly = "settings.imagesOnly"
        static let sound = "settings.playCompleteSound"
        static let menuBar = "settings.showMenuBar"
        static let autoUpdate = "settings.checkUpdatesAutomatically"
    }
}

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var concurrentUploads: Int {
        get {
            access(keyPath: \.concurrentUploads)
            return _concurrentUploads
        }
        set {
            withMutation(keyPath: \.concurrentUploads) {
                _concurrentUploads = min(6, max(1, newValue))
                defaults.set(_concurrentUploads, forKey: Keys.concurrent)
            }
        }
    }
    var convertHEIC: Bool {
        didSet { defaults.set(convertHEIC, forKey: Keys.heic) }
    }
    var imagesOnly: Bool {
        didSet { defaults.set(imagesOnly, forKey: Keys.imagesOnly) }
    }
    var preferredViewMode: BrowserViewMode {
        didSet { defaults.set(preferredViewMode.rawValue, forKey: Keys.preferredViewMode) }
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
    var concurrentDownloads: Int {
        get {
            access(keyPath: \.concurrentDownloads)
            return _concurrentDownloads
        }
        set {
            withMutation(keyPath: \.concurrentDownloads) {
                _concurrentDownloads = min(6, max(1, newValue))
                defaults.set(_concurrentDownloads, forKey: Keys.concurrentDownloads)
            }
        }
    }
    var transferConflictPolicy: TransferConflictPolicy {
        didSet { defaults.set(transferConflictPolicy.rawValue, forKey: Keys.conflictPolicy) }
    }
    var uploadSpeedLimit: TransferSpeedLimit {
        didSet { defaults.set(uploadSpeedLimit.rawValue, forKey: Keys.uploadSpeed) }
    }
    var downloadSpeedLimit: TransferSpeedLimit {
        didSet { defaults.set(downloadSpeedLimit.rawValue, forKey: Keys.downloadSpeed) }
    }
    var downloadLocation: DownloadLocation {
        didSet { defaults.set(downloadLocation.rawValue, forKey: Keys.downloadLocation) }
    }
    var signedLinkLifetime: SignedLinkLifetime {
        didSet { defaults.set(signedLinkLifetime.rawValue, forKey: Keys.signedLinkLifetime) }
    }
    var notifyWhenTransfersFinish: Bool {
        didSet { defaults.set(notifyWhenTransfersFinish, forKey: Keys.transferNotifications) }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            appearance.apply()
        }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var _concurrentUploads: Int
    @ObservationIgnored private var _concurrentDownloads: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Keys.concurrent) as? Int
        self._concurrentUploads = min(6, max(1, stored ?? 3))
        self.convertHEIC = defaults.object(forKey: Keys.heic) as? Bool ?? false
        self.imagesOnly = defaults.object(forKey: Keys.imagesOnly) as? Bool ?? true
        self.preferredViewMode = defaults.string(forKey: Keys.preferredViewMode)
            .flatMap(BrowserViewMode.init(rawValue:)) ?? .grid
        self.playCompleteSound = defaults.bool(forKey: Keys.sound)
        self.showMenuBarWhileTransferring = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        self.checkUpdatesAutomatically = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        let storedDownloads = defaults.object(forKey: Keys.concurrentDownloads) as? Int
        self._concurrentDownloads = min(6, max(1, storedDownloads ?? 3))
        self.transferConflictPolicy = defaults.string(forKey: Keys.conflictPolicy)
            .flatMap(TransferConflictPolicy.init(rawValue:)) ?? .ask
        self.uploadSpeedLimit = TransferSpeedLimit(
            rawValue: (defaults.object(forKey: Keys.uploadSpeed) as? NSNumber)?.int64Value ?? 0
        )
        self.downloadSpeedLimit = TransferSpeedLimit(
            rawValue: (defaults.object(forKey: Keys.downloadSpeed) as? NSNumber)?.int64Value ?? 0
        )
        self.downloadLocation = defaults.string(forKey: Keys.downloadLocation)
            .flatMap(DownloadLocation.init(rawValue:)) ?? .ask
        self.signedLinkLifetime = SignedLinkLifetime(
            rawValue: defaults.integer(forKey: Keys.signedLinkLifetime)
        ) ?? .oneHour
        self.notifyWhenTransfersFinish = defaults.object(forKey: Keys.transferNotifications) as? Bool ?? true
        self.appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    private enum Keys {
        static let concurrent = "settings.concurrentUploads"
        static let heic = "settings.convertHEIC"
        static let imagesOnly = "settings.imagesOnly"
        static let preferredViewMode = "settings.preferredViewMode"
        static let sound = "settings.playCompleteSound"
        static let menuBar = "settings.showMenuBar"
        static let autoUpdate = "settings.checkUpdatesAutomatically"
        static let concurrentDownloads = "settings.concurrentDownloads"
        static let conflictPolicy = "settings.transferConflictPolicy"
        static let uploadSpeed = "settings.uploadSpeedLimit"
        static let downloadSpeed = "settings.downloadSpeedLimit"
        static let downloadLocation = "settings.downloadLocation"
        static let signedLinkLifetime = "settings.signedLinkLifetime"
        static let transferNotifications = "settings.transferNotifications"
        static let appearance = "settings.appearance"
    }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

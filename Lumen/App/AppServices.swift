import AppKit
import Foundation
import Observation

enum AppLinks {
    static let github = URL(string: "https://github.com/ihopefulChina/Lumen")!
    static let releases = URL(string: "https://github.com/ihopefulChina/Lumen/releases")!
    static let issues = URL(string: "https://github.com/ihopefulChina/Lumen/issues")!
}

@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    var accounts: [OSSAccount]
    var settings = AppSettings()
    var transfers = TransferEngine()
    var updates = AppUpdater()
    var favorites = FavoriteStore()
    var showMenuBarExtra = false
    weak var focused: AppModel?

    private var didBootstrap = false
    private var sessionBoxes: [WeakSession] = []
    private var pendingIncomingURLs: [URL] = []

    init(
        accounts: [OSSAccount]? = nil,
        settings: AppSettings = AppSettings(),
        transfers: TransferEngine = TransferEngine(),
        updates: AppUpdater = AppUpdater(),
        favorites: FavoriteStore = FavoriteStore()
    ) {
        self.accounts = accounts ?? AccountStore.load()
        self.settings = settings
        self.transfers = transfers
        self.updates = updates
        self.favorites = favorites
    }

    var sessions: [AppModel] {
        sessionBoxes.compactMap(\.value)
    }

    func register(_ session: AppModel) {
        sessionBoxes.removeAll { $0.value == nil }
        if !sessionBoxes.contains(where: { $0.value === session }) {
            sessionBoxes.append(WeakSession(session))
        }
        focused = session
        if !pendingIncomingURLs.isEmpty {
            let queued = pendingIncomingURLs
            pendingIncomingURLs = []
            session.ingestIncoming(queued)
        }
    }

    func unregister(_ session: AppModel) {
        sessionBoxes.removeAll { $0.value == nil || $0.value === session }
        if focused === session {
            focused = sessions.first
        }
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        updates.automaticallyChecksForUpdates = settings.checkUpdatesAutomatically
        transfers.onUploadFinished = { [weak self] in
            self?.sessions.forEach { $0.scheduleListingRefresh() }
        }
    }

    func presentOnFocused(_ text: String, error: Bool = false) {
        focused?.present(text, error: error)
    }

    func routeIncoming(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let target = focused ?? sessions.first {
            target.ingestIncoming(urls)
        } else {
            pendingIncomingURLs.append(contentsOf: urls)
        }
    }
}

private final class WeakSession {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}

import AppKit
import Foundation
import Observation
import UserNotifications

enum AppLinks {
    static let website = URL(string: "https://ihopefulchina.github.io/Lumen/")!
    static let privacy = URL(string: "https://ihopefulchina.github.io/Lumen/privacy.html")!
    static let support = URL(string: "https://ihopefulchina.github.io/Lumen/support.html")!
    static let github = URL(string: "https://github.com/ihopefulChina/Lumen")!
    static let releases = URL(string: "https://github.com/ihopefulChina/Lumen/releases")!
    static let issues = URL(string: "https://github.com/ihopefulChina/Lumen/issues")!
    static let security = URL(string: "https://github.com/ihopefulChina/Lumen/security/policy")!
    static let privateSecurityReport = URL(string: "https://github.com/ihopefulChina/Lumen/security/advisories/new")!
}

@MainActor
@Observable
final class AppServices {
    private static var sharedStorage: AppServices?
    static var shared: AppServices {
        if let sharedStorage { return sharedStorage }
        let services = AppServices(
            transfers: TransferEngine(journal: FileTransferJournal.live)
        )
        sharedStorage = services
        return services
    }

    var accounts: [OSSAccount]
    var accountRecovery: AccountRecovery?
    var settings = AppSettings()
    var transfers = TransferEngine()
    var updates = AppUpdater()
    var favorites = FavoriteStore()
    var showMenuBarExtra = false
    var transferFilter = TransferFilter.all
    weak var focused: AppModel?

    private var didBootstrap = false
    private var sessionBoxes: [WeakSession] = []
    private var pendingIncomingURLs: [URL] = []
    private var didPresentAccountRecovery = false

    init(
        accounts: [OSSAccount]? = nil,
        settings: AppSettings = AppSettings(),
        transfers: TransferEngine = TransferEngine(),
        updates: AppUpdater = AppUpdater(),
        favorites: FavoriteStore = FavoriteStore()
    ) {
        let loaded = accounts.map { AccountLoadResult(accounts: $0, recovery: nil) } ?? AccountStore.load()
        self.accounts = loaded.accounts
        self.accountRecovery = loaded.recovery
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
        if !didPresentAccountRecovery, let accountRecovery {
            didPresentAccountRecovery = true
            session.present(
                accountRecovery.message,
                error: accountRecovery.kind == .unrecoverable
            )
        }
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
        transfers.concurrency = settings.concurrentUploads
        transfers.downloadConcurrency = settings.concurrentDownloads
        transfers.uploadSpeedLimit = settings.uploadSpeedLimit
        transfers.downloadSpeedLimit = settings.downloadSpeedLimit
        transfers.restore(accounts: accounts)
        updates.automaticallyChecksForUpdates = settings.checkUpdatesAutomatically
        transfers.onUploadFinished = { [weak self] in
            self?.sessions.forEach { $0.scheduleListingRefresh() }
        }
        transfers.onAllFinished = { [weak self] in
            guard let self else { return }
            showMenuBarExtra = false
            guard settings.notifyWhenTransfersFinish else { return }
            let content = UNMutableNotificationContent()
            content.title = "传输已完成"
            content.body = "Lumen 已处理完传输队列。"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
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

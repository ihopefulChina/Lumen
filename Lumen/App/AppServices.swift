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
    var updates = UpdateService()
    var showMenuBarExtra = false
    weak var focused: AppModel?

    private var didBootstrap = false
    private var sessionBoxes: [WeakSession] = []

    init(
        accounts: [OSSAccount]? = nil,
        settings: AppSettings = AppSettings(),
        transfers: TransferEngine = TransferEngine(),
        updates: UpdateService = UpdateService()
    ) {
        self.accounts = accounts ?? AccountStore.load()
        self.settings = settings
        self.transfers = transfers
        self.updates = updates
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
        transfers.onUploadFinished = { [weak self] in
            self?.sessions.forEach { $0.scheduleListingRefresh() }
        }
        if settings.checkUpdatesAutomatically {
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                await updates.checkIfDue()
            }
        }
    }

    func presentOnFocused(_ text: String, error: Bool = false) {
        focused?.present(text, error: error)
    }
}

private final class WeakSession {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}

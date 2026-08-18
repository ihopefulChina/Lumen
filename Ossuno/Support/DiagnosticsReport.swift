import Foundation

enum DiagnosticsReport {
    struct Settings: Sendable {
        var concurrentUploads: Int
        var convertHEIC: Bool
        var imagesOnly: Bool
        var playCompleteSound: Bool
        var showMenuBarWhileTransferring: Bool
        var checkUpdatesAutomatically: Bool
    }

    struct Input: Sendable {
        var version: String
        var build: String
        var operatingSystem: String
        var architecture: String
        var updateFeedHost: String
        var accounts: [OSSAccount]
        var transfers: [TransferJob]
        var settings: Settings
    }

    @MainActor
    static func make(
        services: AppServices = .shared,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? AppVersion.current
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let input = Input(
            version: version,
            build: build,
            operatingSystem: processInfo.operatingSystemVersionString,
            architecture: architecture,
            updateFeedHost: AppUpdater.feedURL.host ?? "unknown",
            accounts: services.accounts,
            transfers: services.transfers.jobs,
            settings: Settings(
                concurrentUploads: services.settings.concurrentUploads,
                convertHEIC: services.settings.convertHEIC,
                imagesOnly: services.settings.imagesOnly,
                playCompleteSound: services.settings.playCompleteSound,
                showMenuBarWhileTransferring: services.settings.showMenuBarWhileTransferring,
                checkUpdatesAutomatically: services.settings.checkUpdatesAutomatically
            )
        )
        return make(input: input)
    }

    static func make(input: Input) -> String {
        let active = input.transfers.filter(\.isActive).count
        let failed = input.transfers.filter { $0.status == .failed }.count
        return """
        Ossuno \(input.version) (\(input.build))
        macOS: \(input.operatingSystem)
        Architecture: \(input.architecture)
        Update feed host: \(input.updateFeedHost)
        Configured accounts: \(input.accounts.count)
        Active transfers: \(active)
        Failed transfers: \(failed)
        Concurrent uploads: \(input.settings.concurrentUploads)
        Convert HEIC: \(yesNo(input.settings.convertHEIC))
        Media-only mode: \(yesNo(input.settings.imagesOnly))
        Completion sound: \(yesNo(input.settings.playCompleteSound))
        Transfer menu bar item: \(yesNo(input.settings.showMenuBarWhileTransferring))
        Automatic update checks: \(yesNo(input.settings.checkUpdatesAutomatically))
        """
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

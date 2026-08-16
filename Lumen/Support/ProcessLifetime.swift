import Foundation

enum ProcessLifetime {
    @MainActor
    private static var transfersActive = false
    @MainActor
    private static var organizing = false
    @MainActor
    private static var didDisable = false

    @MainActor
    static func setTransfersActive(_ active: Bool) {
        transfersActive = active
        apply()
    }

    @MainActor
    static func setOrganizing(_ active: Bool) {
        organizing = active
        apply()
    }

    /// `disableSuddenTermination` / `enableSuddenTermination` are a
    /// reference-counted pair: calling disable repeatedly without a matching
    /// enable would keep sudden termination disabled forever after the first
    /// transfer, so only transition the state.
    @MainActor
    private static func apply() {
        let shouldDisable = transfersActive || organizing
        guard shouldDisable != didDisable else { return }
        if shouldDisable {
            ProcessInfo.processInfo.disableSuddenTermination()
        } else {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
        didDisable = shouldDisable
    }
}

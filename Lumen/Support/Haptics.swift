import AppKit

enum Haptics {
    static func commit() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }

    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    static func levelChange() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

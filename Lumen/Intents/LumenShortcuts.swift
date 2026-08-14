import AppIntents
import Foundation

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FocusLumenIntent(),
            phrases: [
                "打开 \(.applicationName)",
                "用 \(.applicationName) 上传素材"
            ],
            shortTitle: "打开 Lumen",
            systemImageName: "photo.on.rectangle.angled"
        )
    }
}

struct FocusLumenIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Lumen"
    static let description = IntentDescription("把 Lumen 窗口带到前面，准备上传素材。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

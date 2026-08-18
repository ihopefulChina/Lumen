import AppIntents
import Foundation

struct OssunoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FocusOssunoIntent(),
            phrases: [
                "打开 \(.applicationName)",
                "用 \(.applicationName) 上传素材"
            ],
            shortTitle: "打开 Ossuno",
            systemImageName: "photo.on.rectangle.angled"
        )
    }
}

struct FocusOssunoIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Ossuno"
    static let description = IntentDescription("把 Ossuno 窗口带到前面，准备上传素材。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

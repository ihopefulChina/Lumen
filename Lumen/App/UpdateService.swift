import AppKit
import Foundation
import Observation

struct AppRelease: Identifiable, Equatable, Sendable {
    var id: String { version }
    var version: String
    var notes: String
    var pageURL: URL
    var dmgURL: URL?
    var dmgName: String
}

@MainActor
@Observable
final class UpdateService {
    var isChecking = false
    var isDownloading = false
    var available: AppRelease?
    var lastChecked: Date?
    var lastMessage: String?
    var surface: Surface = .workspace

    enum Surface: Equatable {
        case workspace
        case settings
    }

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    func checkIfDue() async {
        let last = defaults.object(forKey: Keys.lastChecked) as? Date
        if let last, Date().timeIntervalSince(last) < 60 * 60 * 20 {
            return
        }
        await check(manual: false)
    }

    func check(manual: Bool, surface: Surface = .workspace) async {
        guard !isChecking, !isDownloading else { return }
        self.surface = surface
        isChecking = true
        lastMessage = nil
        defer { isChecking = false }

        do {
            let release = try await fetchLatest()
            markChecked()
            if AppVersion.isNewer(release.version, than: AppVersion.current) {
                let skipped = defaults.string(forKey: Keys.skipped)
                if !manual, skipped == release.version {
                    lastMessage = "已忽略 \(release.version)"
                    return
                }
                available = release
                lastMessage = "发现 \(release.version)"
            } else {
                available = nil
                lastMessage = "已是最新版本（\(AppVersion.current)）"
            }
        } catch {
            lastMessage = error.localizedDescription
            if manual {
                available = nil
            }
        }
    }

    func skipAvailable() {
        if let version = available?.version {
            defaults.set(version, forKey: Keys.skipped)
        }
        available = nil
    }

    func dismissAvailable() {
        available = nil
    }

    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.pageURL)
    }

    func downloadAndOpen() async {
        guard let available, let remote = available.dmgURL else {
            openReleasePage()
            return
        }
        guard !isDownloading else { return }
        isDownloading = true
        lastMessage = "正在下载 \(available.dmgName)…"
        defer { isDownloading = false }
        do {
            var request = URLRequest(url: remote)
            request.timeoutInterval = 300
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await session.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.http(http.statusCode)
            }
            let dest = try moveToDownloads(temp, name: available.dmgName)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            NSWorkspace.shared.open(dest)
            lastMessage = "已下载到「下载」并打开安装包"
            self.available = nil
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    private func fetchLatest() async throws -> AppRelease {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        if decoded.draft == true {
            throw UpdateError.none
        }
        let version = AppVersion.normalized(decoded.tagName)
        guard !version.isEmpty else { throw UpdateError.none }
        let asset = Self.preferredDMG(in: decoded.assets, version: version)
        return AppRelease(
            version: version,
            notes: decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: decoded.htmlURL,
            dmgURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            dmgName: asset?.name ?? "Lumen-\(version).dmg"
        )
    }

    private func moveToDownloads(_ temp: URL, name: String) throws -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appending(path: "\(UUID().uuidString.prefix(6))-\(name)")
        }
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private func markChecked() {
        let now = Date()
        lastChecked = now
        defaults.set(now, forKey: Keys.lastChecked)
    }

    private var userAgent: String {
        "Lumen/\(AppVersion.current) (macOS)"
    }

    private static func preferredDMG(in assets: [GitHubAsset], version: String) -> GitHubAsset? {
        let dmg = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let exact = "lumen-\(version).dmg"
        if let match = dmg.first(where: { $0.name.lowercased() == exact }) {
            return match
        }
        return dmg.first(where: { $0.name.lowercased().hasPrefix("lumen-") })
    }

    private static let latestURL = URL(string: "https://api.github.com/repos/ihopefulChina/Lumen/releases/latest")!

    private enum Keys {
        static let lastChecked = "updates.lastChecked"
        static let skipped = "updates.skippedVersion"
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var body: String?
    var htmlURL: URL
    var draft: Bool?
    var assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case draft
        case assets
    }
}

private struct GitHubAsset: Decodable {
    var name: String
    var browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateError: LocalizedError {
    case http(Int)
    case none

    var errorDescription: String? {
        switch self {
        case .http(let code): "检查更新失败（\(code)）"
        case .none: "还没有可用的正式版本"
        }
    }
}

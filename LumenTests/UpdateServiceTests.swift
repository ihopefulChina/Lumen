import Foundation
import Testing
@testable import Lumen

struct UpdateServiceTests {
    @Test func acceptsOnlyTheExactVersionedDMG() throws {
        let expected = GitHubAsset(
            name: "Lumen-0.0.3.dmg",
            browserDownloadURL: "https://github.com/ihopefulChina/Lumen/releases/download/v0.0.3/Lumen-0.0.3.dmg"
        )
        let assets = [
            GitHubAsset(
                name: "Lumen-0.0.2.dmg",
                browserDownloadURL: "https://github.com/ihopefulChina/Lumen/releases/download/v0.0.3/Lumen-0.0.2.dmg"
            ),
            GitHubAsset(
                name: "Other-0.0.3.dmg",
                browserDownloadURL: "https://github.com/ihopefulChina/Lumen/releases/download/v0.0.3/Other-0.0.3.dmg"
            ),
            expected,
        ]

        #expect(UpdateService.preferredDMG(in: assets, version: "0.0.3") == expected)
        #expect(UpdateService.preferredDMG(in: [assets[0]], version: "0.0.3") == nil)
        #expect(UpdateService.preferredDMG(in: [assets[1]], version: "0.0.3") == nil)
    }

    @Test func assetNameCannotEscapeDownloads() {
        #expect(UpdateService.safeAssetName("Lumen-0.0.3.dmg") == "Lumen-0.0.3.dmg")
        #expect(UpdateService.safeAssetName("../Lumen-0.0.3.dmg") == nil)
        #expect(UpdateService.safeAssetName("folder/Lumen-0.0.3.dmg") == nil)
        #expect(UpdateService.safeAssetName("Lumen-0.0.3.dmg\u{0}") == nil)
    }

    @Test func assetURLMustPointAtThisRepositoriesExactReleaseAsset() {
        #expect(UpdateService.isTrustedAssetURL(
            URL(string: "https://github.com/ihopefulChina/Lumen/releases/download/v0.0.3/Lumen-0.0.3.dmg")!,
            version: "0.0.3",
            name: "Lumen-0.0.3.dmg"
        ))
        #expect(!UpdateService.isTrustedAssetURL(
            URL(string: "http://github.com/ihopefulChina/Lumen/releases/download/v0.0.3/Lumen-0.0.3.dmg")!,
            version: "0.0.3",
            name: "Lumen-0.0.3.dmg"
        ))
        #expect(!UpdateService.isTrustedAssetURL(
            URL(string: "https://example.com/Lumen-0.0.3.dmg")!,
            version: "0.0.3",
            name: "Lumen-0.0.3.dmg"
        ))
    }
}

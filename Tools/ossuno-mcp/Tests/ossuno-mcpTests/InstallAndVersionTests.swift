import XCTest
@testable import ossuno_mcp

final class InstallAndVersionTests: XCTestCase, @unchecked Sendable {
    func testAllSupportedClientsIncludesClaudeCode() {
        XCTAssertTrue(InstallCommand.supportedClientIDs.contains("claude-code"))
        XCTAssertTrue(InstallCommand.supportedClientIDs.contains("trae"))
        XCTAssertEqual(Set(InstallCommand.supportedClientIDs).count, InstallCommand.supportedClientIDs.count)
    }

    func testVersionHasSingleRuntimeSource() {
        XCTAssertEqual(OssunoMCPVersion.banner, "ossuno-mcp \(OssunoMCPVersion.current)")
        XCTAssertFalse(OssunoMCPVersion.current.isEmpty)
    }
}

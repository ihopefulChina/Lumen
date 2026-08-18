import XCTest
@testable import lumen_mcp

final class InstallAndVersionTests: XCTestCase, @unchecked Sendable {
    func testAllSupportedClientsIncludesClaudeCode() {
        XCTAssertTrue(InstallCommand.supportedClientIDs.contains("claude-code"))
        XCTAssertTrue(InstallCommand.supportedClientIDs.contains("trae"))
        XCTAssertEqual(Set(InstallCommand.supportedClientIDs).count, InstallCommand.supportedClientIDs.count)
    }

    func testVersionHasSingleRuntimeSource() {
        XCTAssertEqual(LumenMCPVersion.banner, "lumen-mcp \(LumenMCPVersion.current)")
        XCTAssertFalse(LumenMCPVersion.current.isEmpty)
    }
}

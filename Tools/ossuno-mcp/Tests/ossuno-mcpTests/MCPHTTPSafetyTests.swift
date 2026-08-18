import XCTest
@testable import ossuno_mcp

final class MCPHTTPSafetyTests: XCTestCase, @unchecked Sendable {
    func testAcceptsNormalContentTypes() throws {
        XCTAssertEqual(
            try MCPHTTPSafety.validatedContentType("application/json; charset=utf-8"),
            "application/json; charset=utf-8"
        )
        XCTAssertNil(try MCPHTTPSafety.validatedContentType("  "))
    }

    func testRejectsHeaderInjectionAndMalformedMediaTypes() {
        XCTAssertThrowsError(
            try MCPHTTPSafety.validatedContentType("image/png\r\nx-oss-meta-secret: leaked")
        )
        XCTAssertThrowsError(try MCPHTTPSafety.validatedContentType("not-a-media-type"))
        XCTAssertThrowsError(try MCPHTTPSafety.validatedContentType("text/pla\u{7f}in"))
    }
}

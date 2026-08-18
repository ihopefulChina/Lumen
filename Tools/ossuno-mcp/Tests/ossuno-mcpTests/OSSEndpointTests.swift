import XCTest
@testable import ossuno_mcp

final class OSSEndpointTests: XCTestCase, @unchecked Sendable {
    func testCustomHTTPEndpointPreservesSchemeAndPort() {
        let profile = MCPOSSProfile(
            name: "test",
            region: "cn-hangzhou",
            accessKeyId: "id",
            accessKeySecret: "secret",
            endpoint: "http://127.0.0.1:9000"
        )
        XCTAssertEqual(profile.apiEndpoint, "http://127.0.0.1:9000")
        XCTAssertEqual(
            OSSEndpoint.parse(profile.apiEndpoint),
            .init(scheme: "http", host: "127.0.0.1", port: 9000)
        )
    }

    func testAliyunHostDetectionRequiresRealDomainSuffix() {
        XCTAssertTrue(OSSEndpoint.isAliyunVirtualHost("oss-cn-hangzhou.aliyuncs.com"))
        XCTAssertFalse(OSSEndpoint.isAliyunVirtualHost("aliyuncs.com.evil.example"))
        XCTAssertFalse(OSSEndpoint.isAliyunVirtualHost("my-aliyuncs.com"))
        XCTAssertEqual(
            OSSEndpoint.parse("http://tenant.oss-proxy.example:9000"),
            .init(scheme: "http", host: "tenant.oss-proxy.example", port: 9000)
        )
        XCTAssertEqual(
            OSSEndpoint.normalize("bucket.oss-cn-hangzhou.aliyuncs.com"),
            "oss-cn-hangzhou.aliyuncs.com"
        )
    }
}

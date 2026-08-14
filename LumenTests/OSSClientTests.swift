import Foundation
import Testing
@testable import Lumen

struct OSSClientTests {
    @Test func downloadPreservesServiceErrorBody() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 403,
                headers: ["x-oss-request-id": "header-request"],
                data: Self.errorXML(code: "AccessDenied", message: "Denied", requestID: "body-request")
            )
        ])
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "lumen-download-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await Self.client(transport: transport).download(key: "private.txt", to: destination)
            Issue.record("Expected OSSServiceError")
        } catch let error as OSSServiceError {
            #expect(error.statusCode == 403)
            #expect(error.code == "AccessDenied")
            #expect(error.message == "Denied")
            #expect(error.requestId == "body-request")
            #expect(error.localizedDescription.contains("AccessDenied"))
            #expect(error.localizedDescription.contains("body-request"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func multipartFailureAbortsUploadExactlyOnce() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .cancel,
            .response(status: 204, headers: [:], data: Data())
        ])
        let file = FileManager.default.temporaryDirectory
            .appending(path: "lumen-multipart-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(OSSClient.multipartThreshold))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: CancellationError.self) {
            try await Self.client(transport: transport).putObject(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[2].httpMethod == "DELETE")
        #expect(requests[2].url?.query == "uploadId=u-1")
    }

    @Test func renameConflictNeverDeletesSource() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 409,
                headers: [:],
                data: Self.errorXML(code: "FileAlreadyExists", message: "Exists", requestID: "rename-request")
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            try await Self.client(transport: transport)
                .renameObject(from: "old name.txt", to: "new name.txt", overwrite: false)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[0].value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
        #expect(requests[0].value(forHTTPHeaderField: "x-oss-copy-source") == "/bucket/old%20name.txt")
    }

    @Test func customEndpointPreservesSchemeAndPort() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".utf8)
            )
        ])
        var client = Self.client(transport: transport)
        client.endpointHost = "http://127.0.0.1:9000"

        _ = try await client.listBuckets()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.scheme == "http")
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.url?.port == 9000)
    }

    @Test func presignedURLPreservesCustomEndpointSchemeAndPort() throws {
        let transport = StubOSSTransport(steps: [])
        var client = Self.client(transport: transport)
        client.endpointHost = "http://127.0.0.1:9000"

        let url = try #require(client.presignedURL(key: "folder/file name.txt"))

        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 9000)
        #expect(url.path(percentEncoded: true) == "/folder/file%20name.txt")
    }

    @Test func truncatedListingWithoutTokenStaysIncomplete() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8)
            )
        ])

        let listing = try await Self.client(transport: transport).listAll(prefix: "folder/")

        #expect(listing.isTruncated)
        #expect(await transport.recordedRequests().count == 1)
    }

    private static func client(transport: any OSSHTTPTransport) -> OSSClient {
        OSSClient(
            credentials: OSSCredentials(
                accessKeyId: "test-id",
                accessKeySecret: "test-secret",
                securityToken: nil
            ),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport
        )
    }

    private static func errorXML(code: String, message: String, requestID: String) -> Data {
        Data("<Error><Code>\(code)</Code><Message>\(message)</Message><RequestId>\(requestID)</RequestId></Error>".utf8)
    }
}

private actor StubOSSTransport: OSSHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String], data: Data)
        case cancel
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        requests.append(request)
        guard !steps.isEmpty else {
            throw OSSServiceError(statusCode: 0, code: "NoStub", message: "Missing stub response", requestId: "")
        }
        switch steps.removeFirst() {
        case .response(let status, let headers, let data):
            return OSSHTTPResult(status: status, headers: headers, data: data, temporaryDownloadURL: nil)
        case .cancel:
            throw CancellationError()
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

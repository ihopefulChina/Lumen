import Foundation
import Testing
@testable import Lumen

@MainActor
struct CloudSafetyRegressionTests {
    @Test func enabledBackupWithoutExactVersionNeverIssuesDelete() async throws {
        for versionHeader in MissingVersionHeader.allCases {
            let account = Self.account(name: "Backup")
            let bucket = Self.bucket(name: "backup-bucket")
            let transport = BackupSafetyTransport(versionHeader: versionHeader)
            let model = Self.model(
                accounts: [account],
                selectedAccount: account,
                buckets: [bucket],
                selectedBucket: bucket,
                transport: transport
            )
            let payload = CloudDragPayload(
                accountID: account.id,
                bucketName: bucket.name,
                sourceRegionID: bucket.regionID,
                objectKeys: ["source.txt"],
                folderPrefixes: []
            )

            let succeeded = await model.organizeCloud(
                payload,
                to: "archive/",
                mode: .copy,
                conflictPolicy: .replace
            )
            let requests = await transport.recordedRequests()

            #expect(!succeeded, "case: \(versionHeader)")
            #expect(model.banner?.isError == true, "case: \(versionHeader)")
            #expect(
                requests.filter { $0.httpMethod == "DELETE" }.isEmpty,
                "Enabled bucket cleanup must not guess a version: \(versionHeader)"
            )
            let backupPUT = try #require(requests.first {
                $0.httpMethod == "PUT" && $0.decodedPath.hasPrefix("/.lumen-rollback/")
            })
            #expect(backupPUT.value(forHTTPHeaderField: "x-oss-object-acl") == "private")
        }
    }

    @Test func crossBucketMoveWithNullSourceVersionKeepsCommittedDestination() async throws {
        let account = Self.account(name: "Move")
        let sourceBucket = Self.bucket(name: "source-bucket")
        let destinationBucket = Self.bucket(name: "destination-bucket")
        let transport = CrossBucketSafetyTransport(
            scenario: .serverSideMoveWithNullSource,
            sourceBucket: sourceBucket.name,
            destinationBucket: destinationBucket.name
        )
        let model = Self.model(
            accounts: [account],
            selectedAccount: account,
            buckets: [sourceBucket, destinationBucket],
            selectedBucket: destinationBucket,
            transport: transport
        )
        let payload = CloudDragPayload(
            accountID: account.id,
            bucketName: sourceBucket.name,
            sourceRegionID: sourceBucket.regionID,
            objectKeys: ["source.txt"],
            folderPrefixes: []
        )

        await Self.prepareAndConfirmCrossOperation(
            model: model,
            payload: payload,
            mode: .move
        )
        try await Self.waitForCrossOperation(model)
        let requests = await transport.recordedRequests()

        #expect(requests.contains {
            $0.httpMethod == "PUT" && $0.decodedPath == "/archive/source.txt"
        })
        #expect(
            requests.filter { $0.httpMethod == "DELETE" }.isEmpty,
            "The null source version must never become an unscoped source DELETE"
        )
        #expect(model.banner?.isError == true)
        #expect(model.banner?.text.contains("来源、目标和安全副本均已保留") == true)
    }

    @Test func relayStagingWithoutExactVersionNeverIssuesDelete() async throws {
        for versionHeader in MissingVersionHeader.allCases {
            let sourceAccount = Self.account(name: "Relay Source")
            let destinationAccount = Self.account(name: "Relay Destination")
            let sourceBucket = Self.bucket(name: "relay-source")
            let destinationBucket = Self.bucket(name: "relay-destination")
            let transport = CrossBucketSafetyTransport(
                scenario: .relayStaging(versionHeader),
                sourceBucket: sourceBucket.name,
                destinationBucket: destinationBucket.name
            )
            let model = Self.model(
                accounts: [sourceAccount, destinationAccount],
                selectedAccount: destinationAccount,
                buckets: [destinationBucket],
                selectedBucket: destinationBucket,
                transport: transport
            )
            let payload = CloudDragPayload(
                accountID: sourceAccount.id,
                bucketName: sourceBucket.name,
                sourceRegionID: sourceBucket.regionID,
                objectKeys: ["source.txt"],
                folderPrefixes: []
            )

            await Self.prepareAndConfirmCrossOperation(
                model: model,
                payload: payload,
                mode: .copy
            )
            try await Self.waitForCrossOperation(model)
            let requests = await transport.recordedRequests()

            #expect(
                requests.filter { $0.httpMethod == "DELETE" }.isEmpty,
                "Enabled staging cleanup must preserve an object with no exact version: \(versionHeader)"
            )
            let stagingPUT = try #require(requests.first {
                $0.httpMethod == "PUT" && $0.decodedPath.hasPrefix("/.lumen-staging/")
            }, "Requests: \(Self.requestSummary(requests)); banner: \(model.banner?.text ?? "nil")")
            #expect(stagingPUT.value(forHTTPHeaderField: "x-oss-object-acl") == "private")
            #expect(model.banner?.isError == true)
        }
    }

    @Test func crossBucketMoveNeverRollsBackDestinationsAfterSourceDeleteBegins() async throws {
        let account = Self.account(name: "Partial Move")
        let sourceBucket = Self.bucket(name: "partial-source")
        let destinationBucket = Self.bucket(name: "partial-destination")
        let transport = CrossBucketSafetyTransport(
            scenario: .serverSideMoveWithPartialSourceCleanup,
            sourceBucket: sourceBucket.name,
            destinationBucket: destinationBucket.name
        )
        let model = Self.model(
            accounts: [account],
            selectedAccount: account,
            buckets: [sourceBucket, destinationBucket],
            selectedBucket: destinationBucket,
            transport: transport
        )
        let payload = CloudDragPayload(
            accountID: account.id,
            bucketName: sourceBucket.name,
            sourceRegionID: sourceBucket.regionID,
            // Source cleanup is longest-key-first. The first key has an exact
            // version and is removed; the shorter key then fails with `null`.
            objectKeys: ["first-long.txt", "z.txt"],
            folderPrefixes: []
        )

        await Self.prepareAndConfirmCrossOperation(
            model: model,
            payload: payload,
            mode: .move
        )
        try await Self.waitForCrossOperation(model)
        let requests = await transport.recordedRequests()
        let sourceDeletes = requests.filter {
            $0.httpMethod == "DELETE"
                && $0.url?.host?.hasPrefix(sourceBucket.name + ".") == true
        }
        let destinationDeletes = requests.filter {
            $0.httpMethod == "DELETE"
                && $0.url?.host?.hasPrefix(destinationBucket.name + ".") == true
        }

        #expect(sourceDeletes.count == 1)
        #expect(sourceDeletes.first?.decodedPath == "/first-long.txt")
        #expect(sourceDeletes.first?.queryValue(named: "versionId") == "source-long-v1")
        #expect(destinationDeletes.isEmpty)
        #expect(requests.filter {
            $0.httpMethod == "PUT" && $0.url?.host?.hasPrefix(destinationBucket.name + ".") == true
                && $0.decodedPath.hasPrefix("/archive/")
        }.count == 2)
        #expect(model.banner?.isError == true)
        #expect(model.banner?.text.contains("来源、目标和安全副本均已保留") == true)
    }

    @Test func relayStagingCleanupDeletesOnlyItsExactCommittedVersion() async throws {
        let sourceAccount = Self.account(name: "Cleanup Source")
        let destinationAccount = Self.account(name: "Cleanup Destination")
        let sourceBucket = Self.bucket(name: "cleanup-source")
        let destinationBucket = Self.bucket(name: "cleanup-destination")
        let transport = CrossBucketSafetyTransport(
            scenario: .relayWithExactStagingVersion,
            sourceBucket: sourceBucket.name,
            destinationBucket: destinationBucket.name
        )
        let model = Self.model(
            accounts: [sourceAccount, destinationAccount],
            selectedAccount: destinationAccount,
            buckets: [destinationBucket],
            selectedBucket: destinationBucket,
            transport: transport
        )
        let payload = CloudDragPayload(
            accountID: sourceAccount.id,
            bucketName: sourceBucket.name,
            sourceRegionID: sourceBucket.regionID,
            objectKeys: ["source.txt"],
            folderPrefixes: []
        )

        await Self.prepareAndConfirmCrossOperation(
            model: model,
            payload: payload,
            mode: .copy
        )
        try await Self.waitForCrossOperation(model)
        let requests = await transport.recordedRequests()
        let deletes = requests.filter { $0.httpMethod == "DELETE" }

        #expect(
            deletes.count == 1,
            "Requests: \(Self.requestSummary(requests)); banner: \(model.banner?.text ?? "nil")"
        )
        let cleanup = try #require(
            deletes.first,
            "Requests: \(Self.requestSummary(requests)); banner: \(model.banner?.text ?? "nil")"
        )
        #expect(cleanup.decodedPath.hasPrefix("/.lumen-staging/"))
        #expect(cleanup.queryValue(named: "versionId") == "staging-v1")
        #expect(deletes.allSatisfy {
            guard let versionID = $0.queryValue(named: "versionId") else { return false }
            return !versionID.isEmpty && versionID.caseInsensitiveCompare("null") != .orderedSame
        })
        let stagingPUT = try #require(requests.first {
            $0.httpMethod == "PUT" && $0.decodedPath.hasPrefix("/.lumen-staging/")
        })
        #expect(stagingPUT.value(forHTTPHeaderField: "x-oss-object-acl") == "private")
        #expect(model.banner?.isError == false)
    }

    private static func prepareAndConfirmCrossOperation(
        model: AppModel,
        payload: CloudDragPayload,
        mode: CloudOperationMode
    ) async {
        let completedSynchronously = await model.organizeCloud(
            payload,
            to: "archive/",
            mode: mode,
            conflictPolicy: .skip
        )
        #expect(!completedSynchronously)
        #expect(model.crossBucketPreflight != nil)
        model.confirmCrossBucketOperation()
    }

    private static func waitForCrossOperation(_ model: AppModel) async throws {
        for _ in 0..<300 {
            if model.crossBucketPreflight == nil,
               !model.isOrganizingCloud,
               model.banner != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the cross-bucket operation")
    }

    private static func requestSummary(_ requests: [URLRequest]) -> String {
        requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "nil")" }
            .joined(separator: " | ")
    }

    private static func model(
        accounts: [OSSAccount],
        selectedAccount: OSSAccount,
        buckets: [OSSBucket],
        selectedBucket: OSSBucket,
        transport: any OSSHTTPTransport
    ) -> AppModel {
        let defaults = UserDefaults(suiteName: "Lumen.CloudSafetyRegressionTests.\(UUID().uuidString)")!
        let services = AppServices(
            accounts: accounts,
            settings: AppSettings(defaults: defaults),
            favorites: FavoriteStore(defaults: defaults)
        )
        let model = AppModel(kind: .settings, services: services) { account, bucket in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: account.signingRegion(for: bucket),
                endpointHost: account.apiHost(for: bucket),
                bucket: bucket?.name,
                transport: transport,
                retryPolicy: OSSRetryPolicy(maxAttempts: 1),
                testingVersioningStatusOverride: .enabled
            )
        }
        model.selectedAccountID = selectedAccount.id
        model.buckets = buckets
        model.selectedBucketName = selectedBucket.name
        return model
    }

    private static func account(name: String) -> OSSAccount {
        OSSAccount(
            id: UUID(),
            name: name,
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func bucket(name: String) -> OSSBucket {
        OSSBucket(
            name: name,
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
    }
}

private enum MissingVersionHeader: CaseIterable, CustomStringConvertible, Sendable {
    case absent
    case null

    var value: String? {
        switch self {
        case .absent: nil
        case .null: "null"
        }
    }

    var description: String {
        switch self {
        case .absent: "missing version header"
        case .null: "null version header"
        }
    }
}

private actor BackupSafetyTransport: OSSHTTPTransport {
    private let versionHeader: MissingVersionHeader
    private var requests: [URLRequest] = []

    init(versionHeader: MissingVersionHeader) {
        self.versionHeader = versionHeader
    }

    func recordedRequests() -> [URLRequest] { requests }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        requests.append(request)
        let method = request.httpMethod ?? ""
        let path = request.decodedPath

        if method == "HEAD", path == "/archive/source.txt" {
            return .testResponse(headers: [
                "Content-Length": "7",
                "Content-Type": "text/plain",
                "ETag": "destination-etag",
                "x-oss-version-id": "destination-v1"
            ])
        }
        if method == "GET", request.hasQueryItem(named: "acl") {
            return .testResponse(data: Self.privateACL)
        }
        if method == "GET", request.hasQueryItem(named: "tagging") {
            return .testResponse(data: Self.emptyTags)
        }
        if method == "PUT", path.hasPrefix("/.lumen-rollback/") {
            var headers: [String: String] = [:]
            if let value = versionHeader.value {
                headers["x-oss-version-id"] = value
            }
            return .testResponse(headers: headers)
        }
        if method == "DELETE" {
            return .testResponse(status: 204)
        }
        throw request.unexpectedTestRequest()
    }

    private static let privateACL = Data(
        "<AccessControlPolicy><AccessControlList><Grant>private</Grant></AccessControlList></AccessControlPolicy>".utf8
    )
    private static let emptyTags = Data("<Tagging><TagSet></TagSet></Tagging>".utf8)
}

private actor CrossBucketSafetyTransport: OSSHTTPTransport {
    enum Scenario: Sendable {
        case serverSideMoveWithNullSource
        case serverSideMoveWithPartialSourceCleanup
        case relayStaging(MissingVersionHeader)
        case relayWithExactStagingVersion

        var usesRelay: Bool {
            switch self {
            case .serverSideMoveWithNullSource, .serverSideMoveWithPartialSourceCleanup: false
            case .relayStaging, .relayWithExactStagingVersion: true
            }
        }

        var stagingVersion: String? {
            switch self {
            case .serverSideMoveWithNullSource, .serverSideMoveWithPartialSourceCleanup: nil
            case .relayStaging(let header): header.value
            case .relayWithExactStagingVersion: "staging-v1"
            }
        }
    }

    private let scenario: Scenario
    private let sourceBucket: String
    private let destinationBucket: String
    private let payload = Data("x".utf8)
    private var requests: [URLRequest] = []

    init(scenario: Scenario, sourceBucket: String, destinationBucket: String) {
        self.scenario = scenario
        self.sourceBucket = sourceBucket
        self.destinationBucket = destinationBucket
    }

    func recordedRequests() -> [URLRequest] { requests }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        requests.append(request)
        let method = request.httpMethod ?? ""
        let path = request.decodedPath
        let host = request.url?.host ?? ""
        let isSource = host.hasPrefix(sourceBucket + ".")
        let isDestination = host.hasPrefix(destinationBucket + ".")

        if method == "GET", request.hasQueryItem(named: "list-type") {
            return .testResponse(data: Self.emptyListing)
        }
        if method == "HEAD", isDestination, path.hasPrefix("/archive/") {
            return .testResponse(status: 404)
        }
        if method == "HEAD", isSource {
            return .testResponse(headers: sourceHeaders(for: path))
        }
        if method == "GET", isSource, request.hasQueryItem(named: "acl") {
            return .testResponse(data: Self.publicReadACL)
        }
        if method == "GET", isSource, request.hasQueryItem(named: "tagging") {
            return .testResponse(data: Self.emptyTags)
        }
        if method == "GET", isSource,
           request.value(forHTTPHeaderField: "Range") != nil {
            return .testResponse(
                status: 206,
                headers: [
                    "Content-Range": "bytes 0-0/1",
                    "ETag": "source-etag"
                ],
                data: payload
            )
        }
        if method == "PUT", isDestination, path.hasPrefix("/.lumen-staging/") {
            var headers = ["x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload))]
            if let versionID = scenario.stagingVersion {
                headers["x-oss-version-id"] = versionID
            }
            return .testResponse(headers: headers)
        }
        if method == "HEAD", isDestination, path.hasPrefix("/.lumen-staging/") {
            guard request.queryValue(named: "versionId") != nil else {
                return .testResponse(status: 404)
            }
            return .testResponse(headers: [
                "Content-Length": "1",
                "Content-Type": "text/plain",
                "ETag": "staging-etag",
                "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload)),
                "x-oss-version-id": "staging-v1"
            ])
        }
        if method == "PUT", isDestination, path.hasPrefix("/archive/") {
            return .testResponse(headers: ["x-oss-version-id": "destination-v1"])
        }
        if method == "DELETE" {
            return .testResponse(status: 204)
        }
        throw request.unexpectedTestRequest()
    }

    private func sourceHeaders(for path: String) -> [String: String] {
        let versionID: String
        switch scenario {
        case .serverSideMoveWithNullSource:
            versionID = "null"
        case .serverSideMoveWithPartialSourceCleanup:
            versionID = path == "/first-long.txt" ? "source-long-v1" : "null"
        case .relayStaging, .relayWithExactStagingVersion:
            versionID = "source-v1"
        }
        return [
            "Content-Length": "1",
            "Content-Type": "text/plain",
            "ETag": "source-etag",
            "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload)),
            "x-oss-version-id": versionID,
            "x-oss-storage-class": "Standard"
        ]
    }

    private static let publicReadACL = Data(
        "<AccessControlPolicy><AccessControlList><Grant>public-read</Grant></AccessControlList></AccessControlPolicy>".utf8
    )
    private static let emptyTags = Data("<Tagging><TagSet></TagSet></Tagging>".utf8)
    private static let emptyListing = Data(
        "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8
    )
}

private extension OSSHTTPResult {
    static func testResponse(
        status: Int = 200,
        headers: [String: String] = [:],
        data: Data = Data()
    ) -> Self {
        Self(status: status, headers: headers, data: data, temporaryDownloadURL: nil)
    }
}

private extension URLRequest {
    var decodedPath: String {
        (url?.path.removingPercentEncoding).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
    }

    func hasQueryItem(named name: String) -> Bool {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == name }) == true
    }

    func queryValue(named name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    func unexpectedTestRequest() -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "UnexpectedTestRequest",
            message: "Unexpected \(httpMethod ?? "") request: \(url?.absoluteString ?? "nil")",
            requestId: ""
        )
    }
}

import Foundation
import Testing
@testable import Lumen

struct OSSClientTests {
    @Test func retryPolicyRetriesOnlyTransientFailures() {
        let policy = OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })

        #expect(policy.delay(afterAttempt: 1, outcome: .httpStatus(503)) == .milliseconds(500))
        #expect(policy.delay(afterAttempt: 2, outcome: .httpStatus(429)) == .seconds(1))
        #expect(policy.delay(afterAttempt: 3, outcome: .urlError(.timedOut)) == .seconds(2))
        #expect(policy.delay(afterAttempt: 1, outcome: .httpStatus(403)) == nil)
        #expect(policy.delay(afterAttempt: 4, outcome: .httpStatus(503)) == nil)
    }

    @Test func transientFailureRetriesAndRebuildsTheRequest() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 503, headers: [:], data: Self.errorXML(code: "ServiceUnavailable", message: "retry", requestID: "one")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".utf8)
            )
        ])
        let sleeper = RecordingRetrySleeper()
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 }),
            retrySleeper: sleeper
        )

        let buckets = try await client.listBuckets()

        #expect(buckets.isEmpty)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.isEmpty == false })
        #expect(await sleeper.recordedDelays() == [.milliseconds(500)])
    }

    @Test func authenticationFailureIsNeverRetried() async {
        let transport = StubOSSTransport(steps: [
            .response(status: 403, headers: [:], data: Self.errorXML(code: "AccessDenied", message: "denied", requestID: "one"))
        ])
        let sleeper = RecordingRetrySleeper()
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 }),
            retrySleeper: sleeper
        )

        await #expect(throws: OSSServiceError.self) {
            _ = try await client.listBuckets()
        }

        #expect(await transport.recordedRequests().count == 1)
        #expect(await sleeper.recordedDelays().isEmpty)
    }

    @Test func versionedDeleteReturnsAnUndoMarkerAndCanDeleteThatExactVersion() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 204,
                headers: [
                    "X-Oss-Delete-Marker": "true",
                    "x-oss-version-id": "CAEQExiBgMCf3Z2X2BciIGQ4YjU"
                ],
                data: Data()
            ),
            .response(status: 204, headers: [:], data: Data())
        ])
        let client = Self.client(transport: transport)

        let receipt = try await client.deleteObject(key: "folder/file name.txt")
        _ = try await client.deleteObject(
            key: receipt.key,
            versionID: receipt.versionID
        )

        #expect(receipt.isDeleteMarker)
        #expect(receipt.versionID == "CAEQExiBgMCf3Z2X2BciIGQ4YjU")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url?.query == nil)
        #expect(requests[1].url?.query?.contains("versionId=CAEQExiBgMCf3Z2X2BciIGQ4YjU") == true)
    }

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

    @Test func downloadNeverOverwritesAnExistingLocalFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-no-overwrite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "existing.txt")
        let temporary = directory.appending(path: "response.tmp")
        try Data("original".utf8).write(to: destination)
        try Data("replacement".utf8).write(to: temporary)
        let transport = StubOSSTransport(steps: [.download(temporary, headers: [:])])

        await #expect(throws: (any Error).self) {
            try await Self.client(transport: transport).download(
                key: "existing.txt",
                to: destination,
                within: directory
            )
        }

        #expect(try Data(contentsOf: destination) == Data("original".utf8))
    }

    @Test func multipartCancellationPreservesCheckpointWithoutAborting() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .cancel
        ])
        let file = FileManager.default.temporaryDirectory
            .appending(path: "lumen-multipart-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(OSSClient.multipartThreshold))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        let checkpoints = CheckpointRecorder()
        await #expect(throws: CancellationError.self) {
            try await Self.client(transport: transport).putObject(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                onCheckpoint: { checkpoint in
                    checkpoints.append(checkpoint)
                }
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod != "DELETE" })
        #expect(checkpoints.values.last??.uploadID == "u-1")
    }

    @Test func multipartUploadEmitsAReusableCheckpointAfterEveryPart() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "\"etag-1\""], data: Data()),
            .response(status: 200, headers: ["ETag": "\"etag-2\""], data: Data()),
            .response(status: 200, headers: [:], data: Data())
        ])
        let file = try Self.multipartFile(parts: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let checkpoints = CheckpointRecorder()

        _ = try await Self.client(transport: transport).putObject(
            key: "large.bin",
            fileURL: file,
            contentType: "application/octet-stream",
            acl: .private,
            onCheckpoint: { checkpoints.append($0) }
        )

        #expect(checkpoints.values.compactMap { $0?.completedParts.count } == [0, 1, 2])
        #expect(checkpoints.values.last! == nil)
    }

    @Test func multipartUploadSkipsPartsAlreadyInAValidCheckpoint() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: ["ETag": "etag-2"], data: Data()),
            .response(status: 200, headers: [:], data: Data())
        ])
        let file = try Self.multipartFile(parts: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let checkpoint = MultipartUploadCheckpoint(
            bucketName: "bucket",
            objectKey: "large.bin",
            sourceSize: Int64(values.fileSize!),
            sourceModifiedAt: values.contentModificationDate!,
            partSize: OSSClient.partSize,
            uploadID: "u-1",
            completedParts: [MultipartCompletedPart(number: 1, etag: "etag-1")]
        )

        _ = try await Self.client(transport: transport).putObject(
            key: "large.bin",
            fileURL: file,
            contentType: "application/octet-stream",
            acl: .private,
            checkpoint: checkpoint
        )

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url?.query?.contains("partNumber=2") == true)
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].url?.query == "uploadId=u-1")
    }

    @Test func multipartAbortIsAnExplicitDelete() async throws {
        let checkpoint = MultipartUploadCheckpoint(
            bucketName: "bucket",
            objectKey: "large.bin",
            sourceSize: OSSClient.partSize,
            sourceModifiedAt: .distantPast,
            partSize: OSSClient.partSize,
            uploadID: "u-1",
            completedParts: []
        )
        let transport = StubOSSTransport(steps: [
            .response(status: 204, headers: [:], data: Data())
        ])

        try await Self.client(transport: transport).abortMultipartUpload(checkpoint)

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.query == "uploadId=u-1")
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

    @Test func recursiveObjectPageUsesNoDelimiterAndForwardsTheExactToken() async throws {
        let firstPage = Data("""
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>next/token + value</NextContinuationToken>
          <Contents><Key>folder/a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let secondPage = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>folder/nested/b.txt</Key><Size>2</Size><ETag>b</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: firstPage),
            .response(status: 200, headers: [:], data: secondPage)
        ])
        let client = Self.client(transport: transport)

        let first = try await client.listObjectPage(prefix: "folder/")
        let second = try await client.listObjectPage(prefix: "folder/", token: first.nextToken)

        #expect(first.objects.map(\.key) == ["folder/a.txt"])
        #expect(second.objects.map(\.key) == ["folder/nested/b.txt"])
        let requests = await transport.recordedRequests()
        let firstItems = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let secondItems = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!firstItems.contains(where: { $0.name == "delimiter" }))
        #expect(firstItems.contains(URLQueryItem(name: "list-type", value: "2")))
        #expect(firstItems.contains(URLQueryItem(name: "max-keys", value: "1000")))
        #expect(secondItems.contains(URLQueryItem(name: "continuation-token", value: "next/token + value")))
    }

    @Test func recursiveAggregateStopsWhenATruncatedPageOmitsItsToken() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("""
                <ListBucketResult>
                  <IsTruncated>true</IsTruncated>
                  <Contents><Key>a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
                </ListBucketResult>
                """.utf8)
            )
        ])

        let result = try await Self.client(transport: transport).listAllObjects(prefix: "")

        #expect(result.objects.map(\.key) == ["a.txt"])
        #expect(result.truncated)
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func crc64XZMatchesTheStandardCheckVector() {
        #expect(CRC64XZ.checksum(Data("123456789".utf8)) == 0x995D_C9BB_DF19_39FA)
    }

    @Test func putDataReportsMatchingServerCRC64() async throws {
        let data = Data("verified upload".utf8)
        let checksum = CRC64XZ.checksum(data)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["x-oss-hash-crc64ecma": String(checksum)],
                data: Data()
            )
        ])

        let verified = try await Self.client(transport: transport).putData(
            key: "verified.txt",
            data: data,
            contentType: "text/plain",
            acl: .private
        )

        #expect(verified)
    }

    @Test func putDataRejectsMismatchedServerCRC64() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["x-oss-hash-crc64ecma": "1"],
                data: Data()
            )
        ])

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).putData(
                key: "corrupted.txt",
                data: Data("different".utf8),
                contentType: "text/plain",
                acl: .private
            )
        }
    }

    @Test func downloadRejectsMismatchedCRCBeforePublishingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-crc-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.txt")
        let temporary = directory.appending(path: "response.tmp")
        try Data("downloaded bytes".utf8).write(to: temporary)
        let transport = StubOSSTransport(steps: [
            .download(temporary, headers: ["x-oss-hash-crc64ecma": "1"])
        ])

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).download(
                key: "download.txt",
                to: destination,
                within: directory
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func resumableDownloadUsesBoundedByteRangesAndPublishesAtomically() async throws {
        let directory = try Self.temporaryDirectory(named: "range-download")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "large.bin")
        let size = 20 * 1_024 * 1_024
        let first = Data(repeating: 1, count: Int(OSSClient.downloadChunkSize))
        let second = Data(repeating: 2, count: Int(OSSClient.downloadChunkSize))
        let third = Data(repeating: 3, count: size - first.count - second.count)
        let checksum = CRC64XZ.checksum(first + second + third)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(size)",
                    "ETag": "v1",
                    "x-oss-hash-crc64ecma": String(checksum)
                ],
                data: Data()
            ),
            .response(status: 206, headers: [:], data: first),
            .response(status: 206, headers: [:], data: second),
            .response(status: 206, headers: [:], data: third)
        ])
        let recorder = DownloadCheckpointRecorder()

        _ = try await Self.client(transport: transport).downloadResumable(
            key: "large.bin",
            to: destination,
            within: directory,
            expectedSize: Int64(size),
            checkpoint: nil,
            onCheckpoint: { recorder.append($0) }
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect((try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize == size)
        let requests = await transport.recordedRequests()
        #expect(requests.dropFirst().map { $0.value(forHTTPHeaderField: "Range") } == [
            "bytes=0-8388607",
            "bytes=8388608-16777215",
            "bytes=16777216-20971519"
        ])
        #expect(recorder.values.compactMap { $0?.completedBytes } == [0, 8_388_608, 16_777_216, 20_971_520])
        #expect(recorder.values.last! == nil)
    }

    @Test func resumableDownloadContinuesFromACompleteRange() async throws {
        let directory = try Self.temporaryDirectory(named: "range-resume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "large.bin")
        let partialName = ".lumen-known.partial"
        let partial = directory.appending(path: partialName)
        let first = Data(repeating: 1, count: Int(OSSClient.downloadChunkSize))
        try first.write(to: partial)
        let size = 20 * 1_024 * 1_024
        let second = Data(repeating: 2, count: Int(OSSClient.downloadChunkSize))
        let third = Data(repeating: 3, count: size - first.count - second.count)
        let checksum = CRC64XZ.checksum(first + second + third)
        let checkpoint = RangeDownloadCheckpoint(
            bucketName: "bucket",
            objectKey: "large.bin",
            expectedSize: Int64(size),
            etag: "v1",
            chunkSize: OSSClient.downloadChunkSize,
            completedBytes: OSSClient.downloadChunkSize,
            partialFileName: partialName
        )
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(size)",
                    "ETag": "v1",
                    "x-oss-hash-crc64ecma": String(checksum)
                ],
                data: Data()
            ),
            .response(status: 206, headers: [:], data: second),
            .response(status: 206, headers: [:], data: third)
        ])

        _ = try await Self.client(transport: transport).downloadResumable(
            key: "large.bin",
            to: destination,
            within: directory,
            expectedSize: Int64(size),
            checkpoint: checkpoint
        )

        let requests = await transport.recordedRequests()
        #expect(requests.dropFirst().map { $0.value(forHTTPHeaderField: "Range") } == [
            "bytes=8388608-16777215",
            "bytes=16777216-20971519"
        ])
    }

    @Test func resumableDownloadKeepsPartialWhenIntegrityCheckFails() async throws {
        let directory = try Self.temporaryDirectory(named: "range-crc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let bytes = Data("downloaded".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["Content-Length": "\(bytes.count)", "ETag": "v1", "x-oss-hash-crc64ecma": "1"],
                data: Data()
            ),
            .response(status: 206, headers: [:], data: bytes)
        ])
        let recorder = DownloadCheckpointRecorder()

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count),
                checkpoint: nil,
                onCheckpoint: { recorder.append($0) }
            )
        }

        let partialName = try #require(recorder.values.compactMap { $0 }.last?.partialFileName)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: partialName).path))
    }

    @Test func resumableDownloadReplacesAnExistingFileOnlyAfterIntegrityPasses() async throws {
        let directory = try Self.temporaryDirectory(named: "range-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        try Data("original".utf8).write(to: destination)
        let bytes = Data("replaced!".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v2",
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(bytes))
                ],
                data: Data()
            ),
            .response(status: 206, headers: [:], data: bytes)
        ])

        _ = try await Self.client(transport: transport).downloadResumable(
            key: "small.bin",
            to: destination,
            within: directory,
            expectedSize: Int64(bytes.count),
            overwrite: true
        )

        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func failedOverwriteDownloadLeavesTheOriginalFile() async throws {
        let directory = try Self.temporaryDirectory(named: "range-keep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let original = Data("original".utf8)
        try original.write(to: destination)
        let bytes = Data("new".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v2",
                    "x-oss-hash-crc64ecma": "1"
                ],
                data: Data()
            ),
            .response(status: 206, headers: [:], data: bytes)
        ])

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count),
                overwrite: true
            )
        }

        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func prefixPlanPreservesRelativePaths() throws {
        let plan = try CloudObjectOperation.planPrefix(
            source: "old/",
            destination: "new/",
            keys: ["old/", "old/a.jpg", "old/sub/b.jpg"]
        )

        #expect(plan.map(\.destinationKey) == ["new/", "new/a.jpg", "new/sub/b.jpg"])
    }

    @Test func prefixCannotMoveInsideItself() {
        #expect(throws: CloudObjectOperationError.self) {
            try CloudObjectOperation.planPrefix(
                source: "old/",
                destination: "old/sub/",
                keys: ["old/a.jpg"]
            )
        }
    }

    @Test func failedPrefixCopyNeverDeletesASourceObject() async throws {
        let listing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>old/a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
          <Contents><Key>old/b.txt</Key><Size>1</Size><ETag>b</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: listing),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-a")),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-b")),
            .response(status: 200, headers: [:], data: Data()),
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "copy failed", requestID: "copy-b")),
            .response(status: 204, headers: [:], data: Data())
        ])

        await #expect(throws: (any Error).self) {
            try await Self.client(transport: transport).movePrefix(from: "old/", to: "new/")
        }

        let requests = await transport.recordedRequests()
        let deletedPaths = requests
            .filter { $0.httpMethod == "DELETE" }
            .compactMap { $0.url?.path }
        #expect(deletedPaths == ["/new/a.txt"])
        #expect(!deletedPaths.contains(where: { $0.hasPrefix("/old/") }))
    }

    @Test func putObjectForbidsOverwriteUnlessRequested() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "lumen-put-forbid-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: Data()),
            .response(status: 200, headers: [:], data: Data())
        ])
        let client = Self.client(transport: transport)

        _ = try await client.putObject(
            key: "safe.txt",
            fileURL: file,
            contentType: "text/plain",
            acl: .private
        )
        _ = try await client.putObject(
            key: "replace.txt",
            fileURL: file,
            contentType: "text/plain",
            acl: .private,
            overwrite: true
        )

        let requests = await transport.recordedRequests()
        #expect(requests[0].value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
        #expect(requests[1].value(forHTTPHeaderField: "x-oss-forbid-overwrite") == nil)
    }

    @Test func downloadWithoutServerCRCStillPublishesTheDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-missing-crc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.txt")
        let temporary = directory.appending(path: "response.tmp")
        let payload = Data("downloaded bytes".utf8)
        try payload.write(to: temporary)
        let transport = StubOSSTransport(steps: [
            .download(temporary, headers: [:])
        ])

        let verified = try await Self.client(transport: transport).download(
            key: "download.txt",
            to: destination,
            within: directory
        )

        #expect(verified == false)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func putObjectTreatsMatchingForbiddenOverwriteAsSuccess() async throws {
        let payload = Data("same-bytes".utf8)
        let file = FileManager.default.temporaryDirectory
            .appending(path: "lumen-put-exists-\(UUID().uuidString).txt")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let checksum = CRC64XZ.checksum(payload)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 409,
                headers: [:],
                data: Self.errorXML(code: "FileAlreadyExists", message: "Exists", requestID: "exists")
            ),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(payload.count)",
                    "x-oss-hash-crc64ecma": String(checksum)
                ],
                data: Data()
            )
        ])

        let verified = try await Self.client(transport: transport).putObject(
            key: "same.txt",
            fileURL: file,
            contentType: "text/plain",
            acl: .private
        )

        #expect(verified)
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["PUT", "HEAD"])
    }

    @Test func putObjectRejectsADifferentExistingObject() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "lumen-put-conflict-\(UUID().uuidString).txt")
        try Data("local".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(
                status: 409,
                headers: [:],
                data: Self.errorXML(code: "FileAlreadyExists", message: "Exists", requestID: "exists")
            ),
            .response(
                status: 200,
                headers: ["Content-Length": "99"],
                data: Data()
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            try await Self.client(transport: transport).putObject(
                key: "other.txt",
                fileURL: file,
                contentType: "text/plain",
                acl: .private
            )
        }
    }

    @Test func sourceCleanupFailureRemovesUnfinishedDestinations() async throws {
        let listing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>old/a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: listing),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-a")),
            .response(status: 200, headers: ["x-oss-version-id": "copied-v1"], data: Data()),
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "delete failed", requestID: "del-a")),
            .response(status: 204, headers: [:], data: Data())
        ])

        await #expect(throws: CloudObjectOperationError.sourceCleanupFailed("old/a.txt")) {
            try await Self.client(transport: transport).movePrefix(from: "old/", to: "new/")
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "HEAD", "PUT", "DELETE", "DELETE"])
        #expect(requests[3].url?.path == "/old/a.txt")
        #expect(requests[4].url?.path == "/new/a.txt")
        #expect(requests[4].url?.query == "versionId=copied-v1")
    }

    private static func client(
        transport: any OSSHTTPTransport,
        retryPolicy: OSSRetryPolicy = OSSRetryPolicy(maxAttempts: 1, jitter: { 0 }),
        retrySleeper: any OSSRetrySleeping = RecordingRetrySleeper()
    ) -> OSSClient {
        OSSClient(
            credentials: OSSCredentials(
                accessKeyId: "test-id",
                accessKeySecret: "test-secret",
                securityToken: nil
            ),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport,
            retryPolicy: retryPolicy,
            retrySleeper: retrySleeper
        )
    }

    private static func errorXML(code: String, message: String, requestID: String) -> Data {
        Data("<Error><Code>\(code)</Code><Message>\(message)</Message><RequestId>\(requestID)</RequestId></Error>".utf8)
    }

    private static func multipartFile(parts: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lumen-multipart-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Int64(parts) * OSSClient.partSize))
        try handle.close()
        return url
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lumen-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MultipartUploadCheckpoint?] = []

    var values: [MultipartUploadCheckpoint?] { lock.withLock { storage } }

    func append(_ checkpoint: MultipartUploadCheckpoint?) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private final class DownloadCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RangeDownloadCheckpoint?] = []

    var values: [RangeDownloadCheckpoint?] { lock.withLock { storage } }

    func append(_ checkpoint: RangeDownloadCheckpoint?) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private actor StubOSSTransport: OSSHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String], data: Data)
        case download(URL, headers: [String: String])
        case cancel
        case failure(URLError.Code)
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
        case .download(let url, let headers):
            return OSSHTTPResult(status: 200, headers: headers, data: Data(), temporaryDownloadURL: url)
        case .cancel:
            throw CancellationError()
        case .failure(let code):
            throw URLError(code)
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor RecordingRetrySleeper: OSSRetrySleeping {
    private var delays: [Duration] = []

    func sleep(for delay: Duration) async throws {
        delays.append(delay)
    }

    func recordedDelays() -> [Duration] {
        delays
    }
}

import Foundation

struct OSSClient: Sendable {
    var credentials: OSSCredentials
    var region: String
    var endpointHost: String
    var bucket: String?
    var transport: any OSSHTTPTransport
    var retryPolicy: OSSRetryPolicy
    var retrySleeper: any OSSRetrySleeping

    static let multipartThreshold: Int64 = 8 * 1024 * 1024
    static let partSize: Int64 = 8 * 1024 * 1024
    static let maxListPages = 30

    init(
        credentials: OSSCredentials,
        region: String,
        endpointHost: String,
        bucket: String?,
        transport: any OSSHTTPTransport = URLSessionOSSHTTPTransport(),
        retryPolicy: OSSRetryPolicy = OSSRetryPolicy(),
        retrySleeper: any OSSRetrySleeping = TaskOSSRetrySleeper()
    ) {
        self.credentials = credentials
        self.region = region
        self.endpointHost = endpointHost
        self.bucket = bucket
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.retrySleeper = retrySleeper
    }

    var requestHost: String {
        let endpoint = OSSEndpoint.parse(endpointHost)
        guard let bucket, !bucket.isEmpty else { return endpoint.host }
        return OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
    }

    func scoped(to bucket: OSSBucket, account: OSSAccount) -> OSSClient {
        var copy = self
        copy.bucket = bucket.name
        copy.region = account.signingRegion(for: bucket)
        copy.endpointHost = account.apiHost(for: bucket)
        return copy
    }

    func listBuckets() async throws -> [OSSBucket] {
        let response = try await perform(method: "GET", bucket: nil, key: nil)
        return try OSSXML.buckets(from: response.data)
    }

    func listFolder(prefix: String, token: String? = nil) async throws -> ObjectListing {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = [
            ("delimiter", "/"),
            ("list-type", "2"),
            ("max-keys", "1000")
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let token, !token.isEmpty { query.append(("continuation-token", token)) }
        let response = try await perform(method: "GET", bucket: bucket, key: nil, query: query)
        var listing = try OSSXML.listing(from: response.data)
        listing.objects.removeAll { $0.key == prefix || $0.isFolderPlaceholder }
        return listing
    }

    func listAll(prefix: String) async throws -> ObjectListing {
        var folders: [OSSFolder] = []
        var objects: [OSSObject] = []
        var token: String?
        var pages = 0
        var seenTokens = Set<String>()
        var incomplete = false
        repeat {
            pages += 1
            let page = try await listFolder(prefix: prefix, token: token)
            folders.append(contentsOf: page.folders)
            objects.append(contentsOf: page.objects)
            if page.isTruncated {
                guard let next = page.nextToken, !next.isEmpty, seenTokens.insert(next).inserted else {
                    incomplete = true
                    token = nil
                    break
                }
                token = next
            } else {
                token = nil
            }
        } while token != nil && pages < Self.maxListPages
        if token != nil { incomplete = true }
        return ObjectListing(folders: folders, objects: objects, isTruncated: incomplete, nextToken: token)
    }

    /// One recursive page of objects under `prefix`. Unlike `listFolder`, this
    /// request intentionally omits a delimiter so nested keys are returned.
    func listObjectPage(prefix: String, token: String? = nil) async throws -> ObjectListing {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = [
            ("list-type", "2"),
            ("max-keys", "1000")
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let token, !token.isEmpty { query.append(("continuation-token", token)) }
        let response = try await perform(method: "GET", bucket: bucket, key: nil, query: query)
        return try OSSXML.listing(from: response.data)
    }

    /// All objects under `prefix`, including nested keys. No delimiter.
    func listAllObjects(prefix: String, includePlaceholders: Bool = false) async throws -> (objects: [OSSObject], truncated: Bool) {
        var objects: [OSSObject] = []
        var token: String?
        var pages = 0
        var seenTokens = Set<String>()
        var incomplete = false
        repeat {
            pages += 1
            let listing = try await listObjectPage(prefix: prefix, token: token)
            objects.append(contentsOf: listing.objects.filter { object in
                if object.key == prefix {
                    return includePlaceholders && object.isFolderPlaceholder
                }
                if object.isFolderPlaceholder { return includePlaceholders }
                return true
            })
            if listing.isTruncated {
                guard let next = listing.nextToken, !next.isEmpty, seenTokens.insert(next).inserted else {
                    incomplete = true
                    token = nil
                    break
                }
                token = next
            } else {
                token = nil
            }
        } while token != nil && pages < Self.maxListPages
        if token != nil { incomplete = true }
        return (objects, incomplete)
    }

    func objectExists(key: String) async throws -> Bool {
        do {
            _ = try await head(key: key)
            return true
        } catch let error as OSSServiceError where error.statusCode == 404 {
            return false
        }
    }

    func head(key: String) async throws -> ObjectHead {
        guard let bucket else { throw Self.missingBucket }
        let response = try await perform(method: "HEAD", bucket: bucket, key: key)
        let headers = response.headers
        return ObjectHead(
            contentType: headers.value("Content-Type"),
            contentLength: headers.value("Content-Length").flatMap(Int64.init),
            lastModified: headers.value("Last-Modified").flatMap(OSSSigner.rfc822Date(from:)),
            etag: headers.value("ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            acl: headers.value("x-oss-object-acl"),
            storageClass: headers.value("x-oss-storage-class")
        )
    }

    @discardableResult
    func putObject(
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        let size = try fileSize(fileURL)
        let localCRC64 = try CRC64XZ.checksum(fileURL: fileURL)
        if size >= Self.multipartThreshold {
            return try await multipartUpload(
                key: key,
                fileURL: fileURL,
                size: size,
                contentType: contentType,
                acl: acl,
                localCRC64: localCRC64,
                onProgress: onProgress
            )
        }
        var headers = [
            "Content-Type": contentType
        ]
        if acl != .default {
            headers["x-oss-object-acl"] = acl.rawValue
        }
        let response = try await perform(
            method: "PUT",
            bucket: bucket,
            key: key,
            headers: headers,
            fileURL: fileURL,
            onProgress: onProgress
        )
        return try Self.verifyCRC64(local: localCRC64, headers: response.headers)
    }

    @discardableResult
    func putData(key: String, data: Data, contentType: String, acl: ObjectACL) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        var headers = ["Content-Type": contentType]
        if acl != .default {
            headers["x-oss-object-acl"] = acl.rawValue
        }
        let response = try await perform(method: "PUT", bucket: bucket, key: key, headers: headers, body: data)
        return try Self.verifyCRC64(local: CRC64XZ.checksum(data), headers: response.headers)
    }

    @discardableResult
    func deleteObject(key: String, versionID: String? = nil) async throws -> OSSDeleteReceipt {
        guard let bucket else { throw Self.missingBucket }
        let query = versionID.map { [("versionId", $0)] } ?? []
        let response = try await perform(
            method: "DELETE",
            bucket: bucket,
            key: key,
            query: query
        )
        return OSSDeleteReceipt(
            key: key,
            isDeleteMarker: response.headers.value("x-oss-delete-marker")?.lowercased() == "true",
            versionID: response.headers.value("x-oss-version-id")
        )
    }

    func copyObject(from sourceKey: String, to destKey: String, overwrite: Bool = true) async throws {
        guard let bucket else { throw Self.missingBucket }
        let source = "/" + bucket + "/" + OSSSigner.uriEncode(sourceKey, encodeSlash: false)
        var headers = ["x-oss-copy-source": source]
        if !overwrite {
            headers["x-oss-forbid-overwrite"] = "true"
        }
        _ = try await perform(
            method: "PUT",
            bucket: bucket,
            key: destKey,
            headers: headers
        )
    }

    func renameObject(from sourceKey: String, to destKey: String, overwrite: Bool) async throws {
        try await copyObject(from: sourceKey, to: destKey, overwrite: overwrite)
        try await deleteObject(key: sourceKey)
    }

    func copyPrefix(from sourcePrefix: String, to destinationPrefix: String) async throws {
        let mappings = try await prefixMappings(from: sourcePrefix, to: destinationPrefix)
        try await performCloudOperation(mappings, mode: .copy)
    }

    func movePrefix(from sourcePrefix: String, to destinationPrefix: String) async throws {
        let mappings = try await prefixMappings(from: sourcePrefix, to: destinationPrefix)
        try await performCloudOperation(mappings, mode: .move)
    }

    func prefixMappings(from sourcePrefix: String, to destinationPrefix: String) async throws -> [CloudObjectMapping] {
        let listing = try await listAllObjects(prefix: sourcePrefix, includePlaceholders: true)
        guard !listing.truncated else {
            throw CloudObjectOperationError.incompleteListing
        }
        guard !listing.objects.isEmpty else {
            throw CloudObjectOperationError.emptySource
        }
        return try CloudObjectOperation.planPrefix(
            source: sourcePrefix,
            destination: destinationPrefix,
            keys: listing.objects.map(\.key)
        )
    }

    func performCloudOperation(
        _ mappings: [CloudObjectMapping],
        mode: CloudOperationMode
    ) async throws {
        guard !mappings.isEmpty else { throw CloudObjectOperationError.emptySource }
        try CloudObjectOperation.validate(mappings)

        for mapping in mappings {
            try Task.checkCancellation()
            if try await objectExists(key: mapping.destinationKey) {
                throw CloudObjectOperationError.destinationExists(mapping.destinationKey)
            }
        }

        var copied: [CloudObjectMapping] = []
        do {
            for mapping in mappings {
                try Task.checkCancellation()
                try await copyObject(
                    from: mapping.sourceKey,
                    to: mapping.destinationKey,
                    overwrite: false
                )
                copied.append(mapping)
            }
        } catch {
            for mapping in copied.reversed() {
                _ = try? await deleteObject(key: mapping.destinationKey)
            }
            throw error
        }

        guard mode == .move else { return }
        for mapping in mappings.sorted(by: { $0.sourceKey.count > $1.sourceKey.count }) {
            do {
                try await deleteObject(key: mapping.sourceKey)
            } catch {
                throw CloudObjectOperationError.sourceCleanupFailed(mapping.sourceKey)
            }
        }
    }

    @discardableResult
    func download(
        key: String,
        to destination: URL,
        within root: URL? = nil,
        process: String? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        if let root {
            try FileSafety.validate(destination: destination, root: root)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OSSServiceError(
                statusCode: 0,
                code: "LocalFileExists",
                message: "本地已有同名文件，未覆盖",
                requestId: ""
            )
        }
        var query: [(String, String)] = []
        if let process, !process.isEmpty {
            query.append(("x-oss-process", process))
        }
        let response = try await perform(
            method: "GET",
            bucket: bucket,
            key: key,
            query: query,
            downloadTo: destination,
            downloadRoot: root,
            onProgress: onProgress
        )
        return response.headers.value("x-oss-hash-crc64ecma") != nil
    }

    func objectData(key: String, process: String? = nil) async throws -> Data {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = []
        if let process, !process.isEmpty {
            query.append(("x-oss-process", process))
        }
        let response = try await perform(method: "GET", bucket: bucket, key: key, query: query)
        _ = try Self.verifyCRC64(local: CRC64XZ.checksum(response.data), headers: response.headers)
        return response.data
    }

    func presignedURL(key: String, process: String? = nil, expires: Int = 3600) -> URL? {
        guard let bucket else { return nil }
        var extra: [(String, String)] = []
        if let process, !process.isEmpty {
            extra.append(("x-oss-process", process))
        }
        let query = OSSSigner.presignedQuery(
            method: "GET",
            bucket: bucket,
            key: key,
            region: region,
            credentials: credentials,
            extraQuery: extra,
            expires: expires
        )
        var items = URLComponents()
        let endpoint = OSSEndpoint.parse(endpointHost)
        items.scheme = endpoint.scheme
        items.host = requestHost
        items.port = endpoint.port
        items.percentEncodedPath = "/" + OSSSigner.uriEncode(key, encodeSlash: false)
        items.percentEncodedQuery = query
            .map { name, value in
                OSSSigner.uriEncode(name, encodeSlash: true) + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
            }
            .joined(separator: "&")
        return items.url
    }

    // MARK: - Multipart

    private func multipartUpload(
        key: String,
        fileURL: URL,
        size: Int64,
        contentType: String,
        acl: ObjectACL,
        localCRC64: UInt64,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        var initiateHeaders = ["Content-Type": contentType]
        if acl != .default {
            initiateHeaders["x-oss-object-acl"] = acl.rawValue
        }
        let initiated = try await perform(
            method: "POST",
            bucket: bucket,
            key: key,
            query: [("uploads", "")],
            headers: initiateHeaders
        )
        let uploadId = try OSSXML.uploadId(from: initiated.data)
        do {
            var parts: [(Int, String)] = []
            var offset: Int64 = 0
            var partNumber = 1
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            while offset < size {
                try Task.checkCancellation()
                let thisSize = min(Self.partSize, size - offset)
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: Int(thisSize)) ?? Data()
                let partResponse = try await perform(
                    method: "PUT",
                    bucket: bucket,
                    key: key,
                    query: [("partNumber", String(partNumber)), ("uploadId", uploadId)],
                    headers: ["Content-Type": contentType],
                    body: chunk
                )
                let etag = (partResponse.headers.value("ETag") ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !etag.isEmpty else {
                    throw OSSServiceError(statusCode: partResponse.status, code: "MissingETag", message: "分片未返回 ETag", requestId: "")
                }
                parts.append((partNumber, etag))
                offset += thisSize
                partNumber += 1
                onProgress?(offset, size)
            }

            let completeBody = completeXML(parts: parts)
            let completed = try await perform(
                method: "POST",
                bucket: bucket,
                key: key,
                query: [("uploadId", uploadId)],
                headers: ["Content-Type": "application/xml"],
                body: completeBody
            )
            return try Self.verifyCRC64(local: localCRC64, headers: completed.headers)
        } catch {
            let client = self
            await Task.detached {
                _ = try? await client.perform(
                    method: "DELETE",
                    bucket: bucket,
                    key: key,
                    query: [("uploadId", uploadId)],
                    checksCancellation: false
                )
            }.value
            throw error
        }
    }

    private func completeXML(parts: [(Int, String)]) -> Data {
        var xml = "<CompleteMultipartUpload>"
        for (number, etag) in parts {
            xml += "<Part><PartNumber>\(number)</PartNumber><ETag>\"\(etag)\"</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    // MARK: - Transport

    private typealias HTTPResponse = OSSHTTPResult

    private static let missingBucket = OSSServiceError(
        statusCode: 0,
        code: "NoBucket",
        message: "还没有选择存储空间",
        requestId: ""
    )

    private func perform(
        method: String,
        bucket: String?,
        key: String?,
        query: [(String, String)] = [],
        headers extra: [String: String] = [:],
        body: Data? = nil,
        fileURL: URL? = nil,
        downloadTo: URL? = nil,
        downloadRoot: URL? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        checksCancellation: Bool = true
    ) async throws -> HTTPResponse {
        guard let url = makeURL(bucket: bucket, key: key, query: query) else {
            throw OSSServiceError(statusCode: 0, code: "InvalidURL", message: "无法构造请求地址", requestId: "")
        }

        let httpBody: OSSHTTPBody
        if let fileURL {
            httpBody = .file(fileURL)
        } else if let body {
            httpBody = .data(body)
        } else {
            httpBody = .none
        }

        var attempt = 1
        while true {
            if checksCancellation {
                try Task.checkCancellation()
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = body != nil || fileURL != nil ? 60 * 30 : 60
            let signed = OSSSigner.signedHeaders(
                method: method,
                bucket: bucket,
                key: key,
                region: region,
                credentials: credentials,
                query: query,
                extraHeaders: extra
            )
            for (name, value) in signed {
                request.setValue(value, forHTTPHeaderField: name)
            }

            do {
                let result = try await transport.send(
                    request,
                    body: httpBody,
                    download: downloadTo != nil,
                    onProgress: onProgress
                )
                if let delay = retryPolicy.delay(
                    afterAttempt: attempt,
                    outcome: .httpStatus(result.status)
                ) {
                    if let temporaryURL = result.temporaryDownloadURL {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    try await retrySleeper.sleep(for: delay)
                    attempt += 1
                    continue
                }

                let http: HTTPResponse
                do {
                    http = try validated(result)
                } catch {
                    if let temporaryURL = result.temporaryDownloadURL {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    throw error
                }

                if let downloadTo {
                    guard let temp = http.temporaryDownloadURL else {
                        throw OSSServiceError(statusCode: 0, code: "MissingDownload", message: "下载没有返回文件", requestId: "")
                    }
                    do {
                        if let downloadRoot {
                            try FileSafety.validate(destination: downloadTo, root: downloadRoot)
                        }
                        guard !FileManager.default.fileExists(atPath: downloadTo.path) else {
                            throw OSSServiceError(
                                statusCode: 0,
                                code: "LocalFileExists",
                                message: "本地已有同名文件，未覆盖",
                                requestId: ""
                            )
                        }
                        let localCRC64 = try CRC64XZ.checksum(fileURL: temp)
                        _ = try Self.verifyCRC64(local: localCRC64, headers: http.headers)
                        try FileManager.default.createDirectory(at: downloadTo.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if let downloadRoot {
                            try FileSafety.validate(destination: downloadTo, root: downloadRoot)
                        }
                        try FileManager.default.moveItem(at: temp, to: downloadTo)
                    } catch {
                        try? FileManager.default.removeItem(at: temp)
                        throw error
                    }
                }
                return http
            } catch {
                if error is CancellationError { throw error }
                guard let outcome = retryPolicy.outcome(for: error),
                      let delay = retryPolicy.delay(afterAttempt: attempt, outcome: outcome)
                else { throw error }
                try await retrySleeper.sleep(for: delay)
                attempt += 1
            }
        }
    }

    private static func verifyCRC64(local: UInt64, headers: [String: String]) throws -> Bool {
        guard let serverValue = headers.value("x-oss-hash-crc64ecma") else {
            return false
        }
        guard let remote = UInt64(serverValue), remote == local else {
            throw OSSIntegrityError(localCRC64: local, serverValue: serverValue)
        }
        return true
    }

    private func validated(_ response: HTTPResponse) throws -> HTTPResponse {
        if !(200...299).contains(response.status) {
            var error = OSSXML.parseError(response.data, status: response.status)
            if error.requestId.isEmpty {
                error.requestId = response.headers.value("x-oss-request-id") ?? ""
            }
            throw error
        }
        return response
    }

    private func makeURL(bucket: String?, key: String?, query: [(String, String)]) -> URL? {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(endpointHost)
        components.scheme = endpoint.scheme
        components.port = endpoint.port
        if let bucket, !bucket.isEmpty {
            components.host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
            if let key, !key.isEmpty {
                components.percentEncodedPath = "/" + OSSSigner.uriEncode(key, encodeSlash: false)
            } else {
                components.path = "/"
            }
        } else {
            components.host = endpoint.host
            components.path = "/"
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { name, value in
                    let encodedName = OSSSigner.uriEncode(name, encodeSlash: true)
                    if value.isEmpty { return encodedName }
                    return encodedName + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
                }
                .joined(separator: "&")
        }
        return components.url
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

private extension Dictionary where Key == String, Value == String {
    func value(_ name: String) -> String? {
        let target = name.lowercased()
        return first(where: { $0.key.lowercased() == target })?.value
    }
}

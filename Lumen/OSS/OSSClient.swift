import Foundation

struct OSSClient: Sendable {
    var credentials: OSSCredentials
    var region: String
    var endpointHost: String
    var bucket: String?

    static let multipartThreshold: Int64 = 8 * 1024 * 1024
    static let partSize: Int64 = 8 * 1024 * 1024
    static let maxListPages = 30

    var requestHost: String {
        guard let bucket, !bucket.isEmpty else { return endpointHost }
        return OSSEndpoint.objectHost(endpoint: endpointHost, bucketName: bucket)
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
        repeat {
            pages += 1
            let page = try await listFolder(prefix: prefix, token: token)
            folders.append(contentsOf: page.folders)
            objects.append(contentsOf: page.objects)
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil && pages < Self.maxListPages
        return ObjectListing(folders: folders, objects: objects, isTruncated: token != nil, nextToken: token)
    }

    /// All objects under `prefix`, including nested keys. No delimiter.
    func listAllObjects(prefix: String, includePlaceholders: Bool = false) async throws -> (objects: [OSSObject], truncated: Bool) {
        guard let bucket else { throw Self.missingBucket }
        var objects: [OSSObject] = []
        var token: String?
        var pages = 0
        repeat {
            pages += 1
            var query: [(String, String)] = [
                ("list-type", "2"),
                ("max-keys", "1000")
            ]
            if !prefix.isEmpty { query.append(("prefix", prefix)) }
            if let token, !token.isEmpty { query.append(("continuation-token", token)) }
            let response = try await perform(method: "GET", bucket: bucket, key: nil, query: query)
            let listing = try OSSXML.listing(from: response.data)
            objects.append(contentsOf: listing.objects.filter { object in
                if object.key == prefix { return false }
                if object.isFolderPlaceholder { return includePlaceholders }
                return true
            })
            token = listing.isTruncated ? listing.nextToken : nil
        } while token != nil && pages < Self.maxListPages
        return (objects, token != nil)
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

    func putObject(
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let bucket else { throw Self.missingBucket }
        let size = try fileSize(fileURL)
        if size >= Self.multipartThreshold {
            try await multipartUpload(key: key, fileURL: fileURL, size: size, contentType: contentType, acl: acl, onProgress: onProgress)
            return
        }
        var headers = [
            "Content-Type": contentType
        ]
        if acl != .default {
            headers["x-oss-object-acl"] = acl.rawValue
        }
        _ = try await perform(
            method: "PUT",
            bucket: bucket,
            key: key,
            headers: headers,
            fileURL: fileURL,
            onProgress: onProgress
        )
    }

    func putData(key: String, data: Data, contentType: String, acl: ObjectACL) async throws {
        guard let bucket else { throw Self.missingBucket }
        var headers = ["Content-Type": contentType]
        if acl != .default {
            headers["x-oss-object-acl"] = acl.rawValue
        }
        _ = try await perform(method: "PUT", bucket: bucket, key: key, headers: headers, body: data)
    }

    func deleteObject(key: String) async throws {
        guard let bucket else { throw Self.missingBucket }
        _ = try await perform(method: "DELETE", bucket: bucket, key: key)
    }

    func copyObject(from sourceKey: String, to destKey: String) async throws {
        guard let bucket else { throw Self.missingBucket }
        let source = "/" + bucket + "/" + OSSSigner.uriEncode(sourceKey, encodeSlash: false)
        _ = try await perform(
            method: "PUT",
            bucket: bucket,
            key: destKey,
            headers: ["x-oss-copy-source": source]
        )
    }

    func download(
        key: String,
        to destination: URL,
        process: String? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = []
        if let process, !process.isEmpty {
            query.append(("x-oss-process", process))
        }
        _ = try await perform(
            method: "GET",
            bucket: bucket,
            key: key,
            query: query,
            downloadTo: destination,
            onProgress: onProgress
        )
    }

    func objectData(key: String, process: String? = nil) async throws -> Data {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = []
        if let process, !process.isEmpty {
            query.append(("x-oss-process", process))
        }
        let response = try await perform(method: "GET", bucket: bucket, key: key, query: query)
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
        items.scheme = "https"
        items.host = requestHost
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
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
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
        var parts: [(Int, String)] = []
        var offset: Int64 = 0
        var partNumber = 1
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        do {
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
            _ = try await perform(
                method: "POST",
                bucket: bucket,
                key: key,
                query: [("uploadId", uploadId)],
                headers: ["Content-Type": "application/xml"],
                body: completeBody
            )
        } catch {
            _ = try? await perform(
                method: "DELETE",
                bucket: bucket,
                key: key,
                query: [("uploadId", uploadId)]
            )
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

    private struct HTTPResponse: Sendable {
        var status: Int
        var headers: [String: String]
        var data: Data
    }

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
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard let url = makeURL(bucket: bucket, key: key, query: query) else {
            throw OSSServiceError(statusCode: 0, code: "InvalidURL", message: "无法构造请求地址", requestId: "")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if body != nil || fileURL != nil {
            request.timeoutInterval = 60 * 30
        }

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

        let delegate = onProgress.map(ProgressMonitor.init)
        let session = URLSession.shared
        let status: Int
        let headers: [String: String]
        let data: Data

        if let downloadTo {
            let (temp, response) = try await session.download(for: request, delegate: delegate)
            let http = try validated(response, data: Data())
            if FileManager.default.fileExists(atPath: downloadTo.path) {
                try FileManager.default.removeItem(at: downloadTo)
            }
            try FileManager.default.createDirectory(at: downloadTo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: downloadTo)
            status = http.status
            headers = http.headers
            data = Data()
        } else if let fileURL {
            let (bodyData, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
            let http = try validated(response, data: bodyData)
            status = http.status
            headers = http.headers
            data = bodyData
        } else if let body {
            let (bodyData, response) = try await session.upload(for: request, from: body, delegate: delegate)
            let http = try validated(response, data: bodyData)
            status = http.status
            headers = http.headers
            data = bodyData
        } else {
            let (bodyData, response) = try await session.data(for: request, delegate: delegate)
            let http = try validated(response, data: bodyData)
            status = http.status
            headers = http.headers
            data = bodyData
        }

        return HTTPResponse(status: status, headers: headers, data: data)
    }

    private func validated(_ response: URLResponse, data: Data) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw OSSServiceError(statusCode: 0, code: "InvalidResponse", message: "响应无效", requestId: "")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        if !(200...299).contains(http.statusCode) {
            throw OSSXML.parseError(data, status: http.statusCode)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, data: data)
    }

    private func makeURL(bucket: String?, key: String?, query: [(String, String)]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        if let bucket, !bucket.isEmpty {
            components.host = OSSEndpoint.objectHost(endpoint: endpointHost, bucketName: bucket)
            if let key, !key.isEmpty {
                components.percentEncodedPath = "/" + OSSSigner.uriEncode(key, encodeSlash: false)
            } else {
                components.path = "/"
            }
        } else {
            components.host = endpointHost
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

private final class ProgressMonitor: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let handler: @Sendable (Int64, Int64) -> Void

    init(_ handler: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        handler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

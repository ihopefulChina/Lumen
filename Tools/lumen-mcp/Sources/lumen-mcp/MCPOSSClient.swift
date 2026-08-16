import Foundation

/// Thin OSS REST client for the MCP server. Single-request operations only —
/// uploads stream the file via URLSession upload; large-file multipart stays
/// in the GUI app.
final class MCPOSSClient: @unchecked Sendable {
    let profile: MCPOSSProfile
    private let session: URLSession

    init(profile: MCPOSSProfile) {
        self.profile = profile
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    // MARK: - URL construction (byte-compatible with Lumen's OSSClient.makeURL)

    private func makeURL(bucket: String?, key: String? = nil, query: [(String, String)] = []) throws -> URL {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(profile.apiEndpoint)
        components.scheme = endpoint.scheme
        components.port = endpoint.port
        if let bucket, !bucket.isEmpty {
            let host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
            components.host = host
            if host == endpoint.host {
                // Path-style endpoint (custom / OSS-compatible host): the
                // bucket goes into the path instead of the host name.
                let encodedBucket = OSSSigner.uriEncode(bucket, encodeSlash: true)
                if let key, !key.isEmpty {
                    components.percentEncodedPath = "/" + encodedBucket + "/" + OSSSigner.uriEncode(key, encodeSlash: false)
                } else {
                    components.percentEncodedPath = "/" + encodedBucket + "/"
                }
            } else if let key, !key.isEmpty {
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
        guard let url = components.url else {
            throw OSSServiceError(statusCode: 0, code: "InvalidURL", message: "无法构造请求 URL", requestId: "")
        }
        return url
    }

    // MARK: - Core request

    private func makeSignedRequest(
        method: String,
        bucket: String?,
        key: String? = nil,
        query: [(String, String)] = [],
        headers extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        let url = try makeURL(bucket: bucket, key: key, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        let signed = OSSSigner.signedHeaders(
            method: method,
            bucket: bucket,
            key: key,
            region: profile.signingRegion,
            credentials: profile.credentials,
            query: query,
            extraHeaders: extraHeaders
        )
        for (name, value) in signed {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func perform(
        method: String,
        bucket: String?,
        key: String? = nil,
        query: [(String, String)] = [],
        headers extraHeaders: [String: String] = [:],
        body: Data? = nil,
        fileURL: URL? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeSignedRequest(
            method: method,
            bucket: bucket,
            key: key,
            query: query,
            headers: extraHeaders
        )

        let data: Data
        let response: URLResponse
        do {
            if let fileURL {
                (data, response) = try await session.upload(for: request, fromFile: fileURL)
            } else if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let urlError as URLError {
            throw OSSServiceError(
                statusCode: 0,
                code: "NetworkError",
                message: "网络请求失败：\(urlError.localizedDescription)",
                requestId: ""
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw OSSServiceError(statusCode: 0, code: "InvalidResponse", message: "非 HTTP 响应", requestId: "")
        }
        guard (200...299).contains(http.statusCode) else {
            throw OSSXML.parseError(data, status: http.statusCode)
        }
        return (data, http)
    }

    // MARK: - Operations

    func listBuckets() async throws -> [OSSBucket] {
        let (data, _) = try await perform(method: "GET", bucket: nil)
        return try OSSXML.buckets(from: data)
    }

    func listObjects(
        bucket: String,
        prefix: String? = nil,
        delimiter: String? = "/",
        maxKeys: Int = 200,
        token: String? = nil
    ) async throws -> ObjectListing {
        var query: [(String, String)] = [
            ("list-type", "2"),
            ("max-keys", String(max(min(maxKeys, 1000), 1))),
        ]
        if let prefix, !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter, !delimiter.isEmpty { query.append(("delimiter", delimiter)) }
        if let token, !token.isEmpty { query.append(("continuation-token", token)) }
        let (data, _) = try await perform(method: "GET", bucket: bucket, query: query)
        var listing = try OSSXML.listing(from: data)
        // Hierarchical mode shows folders separately; drop the "folder/"
        // placeholder objects so AI doesn't see them twice (matches the GUI).
        if delimiter != nil {
            listing.objects.removeAll { $0.isFolderPlaceholder }
        }
        return listing
    }

    struct UploadResult: Sendable {
        var bucket: String
        var key: String
        var size: Int64
        var etag: String
        var url: URL
    }

    func uploadFile(bucket: String, key: String, fileURL: URL, contentType: String?) async throws -> UploadResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? Int64) ?? 0
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        let (data, http) = try await perform(
            method: "PUT",
            bucket: bucket,
            key: key,
            headers: headers,
            fileURL: fileURL
        )
        _ = data
        let etag = http.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        return UploadResult(
            bucket: bucket,
            key: key,
            size: size,
            etag: etag,
            url: try publicURL(bucket: bucket, key: key)
        )
    }

    struct DownloadResult: Sendable {
        var bucket: String
        var key: String
        var localPath: String
        var size: Int64
    }

    func downloadFile(bucket: String, key: String, to destination: URL) async throws -> DownloadResult {
        // Never silently overwrite local files — mirrors the GUI app's boundary.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OSSServiceError(
                statusCode: 0,
                code: "LocalFileExists",
                message: "本地已存在同名文件，未覆盖：\(destination.path)。请换一个保存路径，或先删除该文件。",
                requestId: ""
            )
        }
        let request = try makeSignedRequest(method: "GET", bucket: bucket, key: key)
        // Download task streams to a temp file — memory stays flat for huge objects.
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch let urlError as URLError {
            throw OSSServiceError(
                statusCode: 0,
                code: "NetworkError",
                message: "网络请求失败：\(urlError.localizedDescription)",
                requestId: ""
            )
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw OSSServiceError(statusCode: 0, code: "InvalidResponse", message: "非 HTTP 响应", requestId: "")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: tempURL)) ?? Data()
            try? FileManager.default.removeItem(at: tempURL)
            throw OSSXML.parseError(body, status: http.statusCode)
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        return DownloadResult(
            bucket: bucket,
            key: key,
            localPath: destination.path,
            size: size
        )
    }

    /// Shared URL components for object addresses (virtual-host or path style,
    /// preserving a custom endpoint's port).
    private func objectComponents(bucket: String, key: String) throws -> URLComponents {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(profile.apiEndpoint)
        components.scheme = endpoint.scheme
        components.host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
        components.port = endpoint.port
        let encodedKey = OSSSigner.uriEncode(key, encodeSlash: false)
        if components.host == endpoint.host {
            components.percentEncodedPath = "/" + OSSSigner.uriEncode(bucket, encodeSlash: true) + "/" + encodedKey
        } else {
            components.percentEncodedPath = "/" + encodedKey
        }
        return components
    }

    private static func invalidObjectURL() -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "InvalidURL",
            message: "无法构造对象 URL（Bucket 名称或 Key 含非法字符）",
            requestId: ""
        )
    }

    func presignedURL(bucket: String, key: String, expires: Int) throws -> URL {
        let query = OSSSigner.presignedQuery(
            method: "GET",
            bucket: bucket,
            key: key,
            region: profile.signingRegion,
            credentials: profile.credentials,
            expires: expires
        )
        var components = try objectComponents(bucket: bucket, key: key)
        components.percentEncodedQuery = query
            .map { name, value in
                let encodedName = OSSSigner.uriEncode(name, encodeSlash: true)
                if value.isEmpty { return encodedName }
                return encodedName + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
            }
            .joined(separator: "&")
        guard let url = components.url else {
            throw Self.invalidObjectURL()
        }
        return url
    }

    func publicURL(bucket: String, key: String) throws -> URL {
        let components = try objectComponents(bucket: bucket, key: key)
        guard let url = components.url else {
            throw Self.invalidObjectURL()
        }
        return url
    }

    /// Cheap credential check used by `lumen-mcp auth --test`.
    func verifyCredentials() async throws -> Int {
        let buckets = try await listBuckets()
        return buckets.count
    }
}

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

    private func perform(
        method: String,
        bucket: String?,
        key: String? = nil,
        query: [(String, String)] = [],
        headers extraHeaders: [String: String] = [:],
        body: Data? = nil,
        fileURL: URL? = nil
    ) async throws -> (Data, HTTPURLResponse) {
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
        return try OSSXML.listing(from: data)
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
            url: publicURL(bucket: bucket, key: key)
        )
    }

    struct DownloadResult: Sendable {
        var bucket: String
        var key: String
        var localPath: String
        var size: Int64
    }

    func downloadFile(bucket: String, key: String, to destination: URL) async throws -> DownloadResult {
        let (data, _) = try await perform(method: "GET", bucket: bucket, key: key)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return DownloadResult(
            bucket: bucket,
            key: key,
            localPath: destination.path,
            size: Int64(data.count)
        )
    }

    func presignedURL(bucket: String, key: String, expires: Int) -> URL {
        let query = OSSSigner.presignedQuery(
            method: "GET",
            bucket: bucket,
            key: key,
            region: profile.signingRegion,
            credentials: profile.credentials,
            expires: expires
        )
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(profile.apiEndpoint)
        components.scheme = endpoint.scheme
        components.host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
        let encodedKey = OSSSigner.uriEncode(key, encodeSlash: false)
        if components.host == endpoint.host {
            components.percentEncodedPath = "/" + OSSSigner.uriEncode(bucket, encodeSlash: true) + "/" + encodedKey
        } else {
            components.percentEncodedPath = "/" + encodedKey
        }
        components.percentEncodedQuery = query
            .map { name, value in
                let encodedName = OSSSigner.uriEncode(name, encodeSlash: true)
                if value.isEmpty { return encodedName }
                return encodedName + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
            }
            .joined(separator: "&")
        return components.url!
    }

    func publicURL(bucket: String, key: String) -> URL {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(profile.apiEndpoint)
        components.scheme = endpoint.scheme
        components.host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
        let encodedKey = OSSSigner.uriEncode(key, encodeSlash: false)
        if components.host == endpoint.host {
            components.percentEncodedPath = "/" + OSSSigner.uriEncode(bucket, encodeSlash: true) + "/" + encodedKey
        } else {
            components.percentEncodedPath = "/" + encodedKey
        }
        return components.url!
    }

    /// Cheap credential check used by `lumen-mcp auth --test`.
    func verifyCredentials() async throws -> Int {
        let buckets = try await listBuckets()
        return buckets.count
    }
}

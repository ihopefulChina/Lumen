import CryptoKit
import Foundation

enum OSSSigner {
    private static let lock = NSLock()

    private static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func iso8601String(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return iso8601.string(from: date)
    }

    static func rfc822String(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return rfc822.string(from: date)
    }

    static func rfc822Date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return rfc822.date(from: string)
    }

    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if !encodeSlash {
            allowed.insert(charactersIn: "/")
        }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func resourcePath(bucket: String?, key: String?) -> String {
        var path = "/" + (bucket ?? "")
        if let key {
            path += "/" + key
        } else if bucket != nil {
            path += "/"
        }
        return path
    }

    static func signedHeaders(
        method: String,
        bucket: String?,
        key: String?,
        region: String,
        credentials: OSSCredentials,
        query: [(String, String)],
        extraHeaders: [String: String],
        now: Date = .now
    ) -> [String: String] {
        let datetime = iso8601String(from: now)
        let date = String(datetime.prefix(8))
        let scope = "\(date)/\(region)/oss/aliyun_v4_request"

        var headers = extraHeaders
        headers["x-oss-content-sha256"] = "UNSIGNED-PAYLOAD"
        headers["x-oss-date"] = datetime
        headers["Date"] = rfc822String(from: now)
        if let token = credentials.securityToken, !token.isEmpty {
            headers["x-oss-security-token"] = token
        }

        var lowered: [String: String] = [:]
        for (key, value) in headers {
            lowered[key.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let canonicalRequest = canonicalRequest(
            method: method.uppercased(),
            resourcePath: resourcePath(bucket: bucket, key: key),
            query: query,
            headers: lowered
        )
        let stringToSign = """
        OSS4-HMAC-SHA256
        \(datetime)
        \(scope)
        \(sha256Hex(canonicalRequest))
        """
        let signature = hexHMAC(signingKey(secret: credentials.accessKeySecret, date: date, region: region), stringToSign)
        headers["Authorization"] = "OSS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope),Signature=\(signature)"
        return headers
    }

    static func presignedQuery(
        method: String,
        bucket: String?,
        key: String?,
        region: String,
        credentials: OSSCredentials,
        extraQuery: [(String, String)] = [],
        expires: Int = 3600,
        now: Date = .now
    ) -> [(String, String)] {
        let datetime = iso8601String(from: now)
        let date = String(datetime.prefix(8))
        let scope = "\(date)/\(region)/oss/aliyun_v4_request"
        let credential = "\(credentials.accessKeyId)/\(scope)"

        var query: [(String, String)] = extraQuery
        query.append(("x-oss-signature-version", "OSS4-HMAC-SHA256"))
        query.append(("x-oss-date", datetime))
        query.append(("x-oss-expires", String(expires)))
        query.append(("x-oss-credential", credential))
        if let token = credentials.securityToken, !token.isEmpty {
            query.append(("x-oss-security-token", token))
        }

        let canonicalRequest = canonicalRequest(
            method: method.uppercased(),
            resourcePath: resourcePath(bucket: bucket, key: key),
            query: query,
            headers: [:]
        )
        let stringToSign = """
        OSS4-HMAC-SHA256
        \(datetime)
        \(scope)
        \(sha256Hex(canonicalRequest))
        """
        let signature = hexHMAC(signingKey(secret: credentials.accessKeySecret, date: date, region: region), stringToSign)
        query.append(("x-oss-signature", signature))
        return query
    }

    /// OSS V4 canonical request, per the official spec:
    /// `Verb\nCanonicalURI\nCanonicalQueryString\nCanonicalHeaders\nAdditionalHeaders\nHashedPayload`.
    ///
    /// Each canonical header line already ends with "\n"; the `+ "\n"` after
    /// them is the required blank separator, and the `+ "" + "\n"` is the
    /// (empty) AdditionalHeaders line — this app signs only Content-Type,
    /// Content-MD5 and x-oss-* headers, which are never "additional". Both
    /// lines are mandatory: removing the empty one would invalidate every
    /// signature. Byte-identical to SignerV4.cc / the Python SDK v2.
    static func canonicalRequest(
        method: String,
        resourcePath: String,
        query: [(String, String)],
        headers: [String: String]
    ) -> String {
        let canonicalURI = uriEncode(resourcePath, encodeSlash: false)
        var encodedQuery: [(String, String)] = []
        encodedQuery.reserveCapacity(query.count)
        for item in query {
            encodedQuery.append((uriEncode(item.0, encodeSlash: true), uriEncode(item.1, encodeSlash: true)))
        }
        encodedQuery.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        var queryParts: [String] = []
        queryParts.reserveCapacity(encodedQuery.count)
        for item in encodedQuery {
            queryParts.append(item.1.isEmpty ? item.0 : item.0 + "=" + item.1)
        }
        let canonicalQuery = queryParts.joined(separator: "&")

        let signedHeaderKeys = headers.keys.filter { key in
            key == "content-type" || key == "content-md5" || key.hasPrefix("x-oss-")
        }.sorted()
        let canonicalHeaders = signedHeaderKeys
            .map { "\($0):\(headers[$0] ?? "")\n" }
            .joined()

        let hashedPayload = headers["x-oss-content-sha256"] ?? "UNSIGNED-PAYLOAD"
        return method + "\n"
            + canonicalURI + "\n"
            + canonicalQuery + "\n"
            + canonicalHeaders + "\n"
            + "" + "\n"
            + hashedPayload
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func signingKey(secret: String, date: String, region: String) -> SymmetricKey {
        let dateKey = HMAC<SHA256>.authenticationCode(
            for: Data(date.utf8),
            using: SymmetricKey(data: Data("aliyun_v4\(secret)".utf8))
        )
        let regionKey = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: Data(dateKey)))
        let serviceKey = HMAC<SHA256>.authenticationCode(for: Data("oss".utf8), using: SymmetricKey(data: Data(regionKey)))
        let signing = HMAC<SHA256>.authenticationCode(for: Data("aliyun_v4_request".utf8), using: SymmetricKey(data: Data(serviceKey)))
        return SymmetricKey(data: Data(signing))
    }

    static func hexHMAC(_ key: SymmetricKey, _ message: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

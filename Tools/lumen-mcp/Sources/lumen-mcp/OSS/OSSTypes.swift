import Foundation

// Trimmed copy of Lumen/OSS/OSSTypes.swift — only the pieces the CLI needs.

struct OSSCredentials: Sendable, Hashable {
    var accessKeyId: String
    var accessKeySecret: String
    var securityToken: String?
}

struct OSSBucket: Hashable, Codable, Sendable {
    var name: String
    var regionID: String
    var location: String
    var extranetEndpoint: String
    var createdAt: Date?

    var id: String { name }
}

struct OSSObject: Hashable, Codable, Sendable {
    var key: String
    var size: Int64
    var etag: String
    var lastModified: Date?
    var storageClass: String

    var id: String { key }
    var name: String { (key as NSString).lastPathComponent }
    var isFolderPlaceholder: Bool { key.hasSuffix("/") }
}

struct OSSFolder: Hashable, Sendable {
    var prefix: String
    var id: String { prefix }
    var name: String { (prefix.dropLast() as NSString).lastPathComponent }
}

struct ObjectListing: Sendable {
    var folders: [OSSFolder]
    var objects: [OSSObject]
    var isTruncated: Bool
    var nextToken: String?
}

struct OSSServiceError: LocalizedError, Sendable {
    var statusCode: Int
    var code: String
    var message: String
    var requestId: String

    var errorDescription: String? {
        var description = message.isEmpty
            ? (code.isEmpty ? "请求失败（\(statusCode)）" : code)
            : message
        if !code.isEmpty, code != message {
            description += "（\(code)）"
        }
        if !requestId.isEmpty {
            description += "\n请求 ID：\(requestId)"
        }
        return description
    }

    var failureReason: String? {
        requestId.isEmpty ? nil : "请求 ID：\(requestId)"
    }
}

enum OSSEndpoint {
    struct Parsed: Equatable, Sendable {
        var scheme: String
        var host: String
        var port: Int?
    }

    static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let components = URLComponents(string: candidate)
        return Parsed(
            scheme: components?.scheme?.lowercased() == "http" ? "http" : "https",
            host: normalize(components?.host ?? trimmed),
            port: components?.port
        )
    }

    static func normalize(_ raw: String) -> String {
        var host = raw
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        let parts = host.split(separator: ".")
        if parts.count >= 4, parts[1].hasPrefix("oss-") {
            return parts.dropFirst().joined(separator: ".")
        }
        return host
    }

    static func isAliyunVirtualHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value.contains("aliyuncs.com") || value.contains("aliyun-inc.com")
    }

    static func objectHost(endpoint: String, bucketName: String) -> String {
        if isAliyunVirtualHost(endpoint) {
            return "\(bucketName).\(endpoint)"
        }
        return endpoint
    }
}

extension String {
    func strippingOSSPrefix() -> String {
        if hasPrefix("oss-") {
            return String(dropFirst(4))
        }
        return self
    }
}

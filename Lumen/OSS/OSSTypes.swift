import Foundation

struct OSSCredentials: Sendable, Hashable {
    var accessKeyId: String
    var accessKeySecret: String
    var securityToken: String?
}

struct OSSRegion: Identifiable, Hashable, Sendable {
    var id: String
    var name: String

    var publicHost: String { "oss-\(id).aliyuncs.com" }

    static let all: [OSSRegion] = [
        .init(id: "cn-hangzhou", name: "华东1（杭州）"),
        .init(id: "cn-shanghai", name: "华东2（上海）"),
        .init(id: "cn-nanjing", name: "华东5（南京）"),
        .init(id: "cn-fuzhou", name: "华东6（福州）"),
        .init(id: "cn-wuhan", name: "华中1（武汉）"),
        .init(id: "cn-qingdao", name: "华北1（青岛）"),
        .init(id: "cn-beijing", name: "华北2（北京）"),
        .init(id: "cn-zhangjiakou", name: "华北3（张家口）"),
        .init(id: "cn-huhehaote", name: "华北5（呼和浩特）"),
        .init(id: "cn-wulanchabu", name: "华北6（乌兰察布）"),
        .init(id: "cn-shenzhen", name: "华南1（深圳）"),
        .init(id: "cn-heyuan", name: "华南2（河源）"),
        .init(id: "cn-guangzhou", name: "华南3（广州）"),
        .init(id: "cn-chengdu", name: "西南1（成都）"),
        .init(id: "cn-hongkong", name: "中国香港"),
        .init(id: "ap-southeast-1", name: "新加坡"),
        .init(id: "ap-southeast-3", name: "吉隆坡"),
        .init(id: "ap-southeast-5", name: "雅加达"),
        .init(id: "ap-southeast-7", name: "曼谷"),
        .init(id: "ap-northeast-1", name: "东京"),
        .init(id: "ap-northeast-2", name: "首尔"),
        .init(id: "ap-south-1", name: "孟买"),
        .init(id: "us-west-1", name: "硅谷"),
        .init(id: "us-east-1", name: "弗吉尼亚"),
        .init(id: "eu-central-1", name: "法兰克福"),
        .init(id: "eu-west-1", name: "伦敦"),
        .init(id: "me-east-1", name: "迪拜")
    ]

    static func named(_ id: String) -> OSSRegion {
        all.first(where: { $0.id == id }) ?? OSSRegion(id: id, name: id)
    }
}

enum ObjectACL: String, CaseIterable, Identifiable, Codable, Sendable {
    case `default` = "default"
    case `private` = "private"
    case publicRead = "public-read"
    case publicReadWrite = "public-read-write"

    var id: String { rawValue }

    var isPublic: Bool {
        self == .publicRead || self == .publicReadWrite
    }

    var title: String {
        switch self {
        case .default: "继承存储空间"
        case .private: "私有"
        case .publicRead: "公共读"
        case .publicReadWrite: "公共读写"
        }
    }

    var detail: String {
        switch self {
        case .default: "使用 Bucket 的默认权限"
        case .private: "仅持有密钥的人可访问"
        case .publicRead: "链接可直接打开，适合素材分发"
        case .publicReadWrite: "任何人可改写，几乎从不使用"
        }
    }
}

struct OSSAccount: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var accessKeyId: String
    var regionID: String
    var endpointOverride: String
    var cdnDomain: String
    var defaultACL: ObjectACL
    var prefixTemplate: String
    var useTransferAccelerate: Bool
    var createdAt: Date

    var region: OSSRegion { OSSRegion.named(regionID) }

    var displayName: String {
        name.isEmpty ? accessKeyId : name
    }

    func apiHost(for bucket: OSSBucket?) -> String {
        if useTransferAccelerate, bucket != nil {
            return "oss-accelerate.aliyuncs.com"
        }
        let override = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return override.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let endpoint = bucket?.extranetEndpoint, !endpoint.isEmpty {
            return OSSEndpoint.normalize(endpoint)
        }
        if let region = bucket?.regionID, !region.isEmpty {
            return "oss-\(region.strippingOSSPrefix()).aliyuncs.com"
        }
        return region.publicHost
    }

    func objectHost(bucketName: String, bucket: OSSBucket?) -> String {
        let endpoint = OSSEndpoint.parse(apiHost(for: bucket))
        return OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucketName)
    }

    func signingRegion(for bucket: OSSBucket?) -> String {
        if let region = bucket?.regionID, !region.isEmpty {
            return region.strippingOSSPrefix()
        }
        return regionID
    }

    func publicURL(bucketName: String, bucket: OSSBucket?, key: String) -> URL? {
        let cdn = cdnDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = OSSEndpoint.parse(cdn.isEmpty ? apiHost(for: bucket) : cdn)
        let host = cdn.isEmpty
            ? OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucketName)
            : endpoint.host
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = host
        components.port = endpoint.port
        if cdn.isEmpty, host == endpoint.host {
            // Path-style endpoint (custom / OSS-compatible host): the bucket
            // goes into the path instead of being silently dropped.
            components.percentEncodedPath = "/" + OSSSigner.uriEncode(bucketName, encodeSlash: true)
                + "/" + OSSSigner.uriEncode(key, encodeSlash: false)
        } else {
            components.percentEncodedPath = "/" + OSSSigner.uriEncode(key, encodeSlash: false)
        }
        return components.url
    }

    var prefersSignedLinks: Bool {
        cdnDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (defaultACL == .default || defaultACL == .private)
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

struct OSSBucket: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var regionID: String
    var location: String
    var extranetEndpoint: String
    var createdAt: Date?

    var id: String { name }

    var regionLabel: String {
        OSSRegion.named(regionID.strippingOSSPrefix()).name
    }
}

struct OSSObject: Identifiable, Hashable, Codable, Sendable {
    var key: String
    var size: Int64
    var etag: String
    var lastModified: Date?
    var storageClass: String

    var id: String { key }
    var name: String { PathTemplate.lastComponent(key) }
    var isImage: Bool { ImageKind.isImage(key: key) }
    var isText: Bool { ImageKind.isText(key: key) }
    var isSupported: Bool { ImageKind.isSupported(key: key) }
    var isFolderPlaceholder: Bool { key.hasSuffix("/") }
}

struct OSSFolder: Identifiable, Hashable, Sendable {
    var prefix: String
    var id: String { prefix }
    var name: String { PathTemplate.lastComponent(prefix) }
}

struct ObjectListing: Sendable {
    var folders: [OSSFolder]
    var objects: [OSSObject]
    var isTruncated: Bool
    var nextToken: String?
}

struct ObjectHead: Sendable {
    var contentType: String?
    var contentLength: Int64?
    var lastModified: Date?
    var etag: String?
    var acl: String?
    var storageClass: String?
    var crc64: UInt64? = nil
    var cacheControl: String? = nil
    var contentDisposition: String? = nil
    var userMetadata: [String: String] = [:]
    var versionID: String? = nil
}

struct OSSDeleteReceipt: Equatable, Sendable {
    var key: String
    var isDeleteMarker: Bool
    var versionID: String?

    var undoMarker: OSSDeleteMarker? {
        guard isDeleteMarker, let versionID, !versionID.isEmpty else { return nil }
        return OSSDeleteMarker(key: key, versionID: versionID)
    }
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

extension String {
    func strippingOSSPrefix() -> String {
        if hasPrefix("oss-") {
            return String(dropFirst(4))
        }
        return self
    }
}

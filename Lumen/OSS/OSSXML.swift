import Foundation

struct XMLNode: Sendable {
    var name: String
    var text: String
    var children: [XMLNode]

    func child(_ name: String) -> XMLNode? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func children(_ name: String) -> [XMLNode] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var string: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum OSSXML {
    static func parse(_ data: Data) throws -> XMLNode {
        let parser = TreeParser()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = parser
        guard xml.parse(), let root = parser.root else {
            throw OSSServiceError(statusCode: 0, code: "InvalidXML", message: parser.errorMessage ?? "无法解析响应", requestId: "")
        }
        return root
    }

    static func parseError(_ data: Data, status: Int) -> OSSServiceError {
        guard let root = try? parse(data) else {
            let snippet = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return OSSServiceError(statusCode: status, code: "HTTPError", message: snippet.isEmpty ? "请求失败（\(status)）" : snippet, requestId: "")
        }
        return OSSServiceError(
            statusCode: status,
            code: root.child("Code")?.string ?? "HTTPError",
            message: root.child("Message")?.string ?? "请求失败（\(status)）",
            requestId: root.child("RequestId")?.string ?? ""
        )
    }

    static func buckets(from data: Data) throws -> [OSSBucket] {
        let root = try parse(data)
        let list = root.child("Buckets") ?? root
        return list.children("Bucket").compactMap { node in
            guard let name = node.child("Name")?.string, !name.isEmpty else { return nil }
            let location = node.child("Location")?.string ?? ""
            let region = node.child("Region")?.string ?? location.strippingOSSPrefix()
            return OSSBucket(
                name: name,
                regionID: region.strippingOSSPrefix(),
                location: location,
                extranetEndpoint: node.child("ExtranetEndpoint")?.string ?? "",
                createdAt: ISO8601DateParser.date(node.child("CreationDate")?.string)
            )
        }
    }

    static func listing(from data: Data) throws -> ObjectListing {
        let root = try parse(data)
        let folders = root.children("CommonPrefixes").compactMap { node -> OSSFolder? in
            guard let prefix = node.child("Prefix")?.string, !prefix.isEmpty else { return nil }
            return OSSFolder(prefix: prefix)
        }
        let objects = root.children("Contents").compactMap { node -> OSSObject? in
            guard let key = node.child("Key")?.string, !key.isEmpty else { return nil }
            return OSSObject(
                key: key,
                size: Int64(node.child("Size")?.string ?? "0") ?? 0,
                etag: (node.child("ETag")?.string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                lastModified: ISO8601DateParser.date(node.child("LastModified")?.string),
                storageClass: node.child("StorageClass")?.string ?? ""
            )
        }
        let truncated = (root.child("IsTruncated")?.string ?? "false").lowercased() == "true"
        return ObjectListing(
            folders: folders,
            objects: objects,
            isTruncated: truncated,
            nextToken: root.child("NextContinuationToken")?.string
        )
    }

    static func versionPage(from data: Data) throws -> OSSVersionPage {
        let root = try parse(data)
        let versions = root.children("Version").compactMap { node -> OSSObjectVersion? in
            guard let key = node.child("Key")?.string,
                  let versionID = node.child("VersionId")?.string,
                  !key.isEmpty, !versionID.isEmpty
            else { return nil }
            return OSSObjectVersion(
                key: key,
                versionID: versionID,
                isLatest: node.child("IsLatest")?.string.lowercased() == "true",
                lastModified: ISO8601DateParser.date(node.child("LastModified")?.string),
                etag: (node.child("ETag")?.string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                size: Int64(node.child("Size")?.string ?? "0") ?? 0,
                storageClass: node.child("StorageClass")?.string ?? ""
            )
        }
        let markers = root.children("DeleteMarker").compactMap { node -> OSSDeleteMarkerVersion? in
            guard let key = node.child("Key")?.string,
                  let versionID = node.child("VersionId")?.string,
                  !key.isEmpty, !versionID.isEmpty
            else { return nil }
            return OSSDeleteMarkerVersion(
                key: key,
                versionID: versionID,
                isLatest: node.child("IsLatest")?.string.lowercased() == "true",
                lastModified: ISO8601DateParser.date(node.child("LastModified")?.string)
            )
        }
        return OSSVersionPage(
            versions: versions,
            deleteMarkers: markers,
            isTruncated: root.child("IsTruncated")?.string.lowercased() == "true",
            nextKeyMarker: root.child("NextKeyMarker")?.string,
            nextVersionIDMarker: root.child("NextVersionIdMarker")?.string
        )
    }

    static func uploadId(from data: Data) throws -> String {
        let root = try parse(data)
        guard let id = root.child("UploadId")?.string, !id.isEmpty else {
            throw OSSServiceError(statusCode: 200, code: "MissingUploadId", message: "未返回分片上传 ID", requestId: "")
        }
        return id
    }

    static func tags(from data: Data) throws -> [OSSObjectTag] {
        let root = try parse(data)
        let set = root.child("TagSet") ?? root
        let tags = set.children("Tag").compactMap { node -> OSSObjectTag? in
            guard let key = node.child("Key")?.string, !key.isEmpty else { return nil }
            return OSSObjectTag(key: key, value: node.child("Value")?.string ?? "")
        }
        guard tags.count <= 10, Set(tags.map { $0.key.lowercased() }).count == tags.count else {
            throw OSSServiceError(statusCode: 0, code: "InvalidTags", message: "对象标签格式无效", requestId: "")
        }
        return tags
    }

    static func taggingData(_ tags: [OSSObjectTag]) -> Data {
        var xml = "<Tagging><TagSet>"
        for tag in tags {
            xml += "<Tag><Key>\(escape(tag.key))</Key><Value>\(escape(tag.value))</Value></Tag>"
        }
        xml += "</TagSet></Tagging>"
        return Data(xml.utf8)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum ISO8601DateParser {
    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

private final class TreeParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    var root: XMLNode?
    var errorMessage: String?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(XMLNode(name: elementName, text: "", children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        errorMessage = parseError.localizedDescription
    }
}

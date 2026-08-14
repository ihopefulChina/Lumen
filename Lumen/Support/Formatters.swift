import Foundation

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }
}

enum ImageKind {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif",
        "tif", "tiff", "bmp", "svg", "avif", "jxl", "ico", "jp2"
    ]

    static let textExtensions: Set<String> = [
        "json", "txt", "text"
    ]

    static func `extension`(of key: String) -> String {
        (key as NSString).pathExtension.lowercased()
    }

    static func isImage(key: String) -> Bool {
        imageExtensions.contains(`extension`(of: key))
    }

    static func isText(key: String) -> Bool {
        textExtensions.contains(`extension`(of: key))
    }

    static func isSupported(key: String) -> Bool {
        isImage(key: key) || isText(key: key)
    }

    static func contentType(for key: String) -> String {
        switch `extension`(of: key) {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "svg": "image/svg+xml"
        case "avif": "image/avif"
        case "jxl": "image/jxl"
        case "ico": "image/x-icon"
        case "jp2": "image/jp2"
        case "json": "application/json"
        case "txt", "text": "text/plain"
        case "pdf": "application/pdf"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }

    static func displayKind(for key: String) -> String {
        let ext = `extension`(of: key).uppercased()
        if ext.isEmpty { return "文件" }
        if isImage(key: key) { return "\(ext) 图片" }
        if ext == "JSON" { return "JSON" }
        if isText(key: key) { return "\(ext) 文本" }
        return "\(ext) 文件"
    }
}

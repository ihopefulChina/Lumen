import Foundation
import UniformTypeIdentifiers

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        if value == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
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
        "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp",
        "png", "apng",
        "gif",
        "webp",
        "bmp", "dib",
        "tif", "tiff",
        "heic", "heif", "heics",
        "avif",
        "svg", "svgz",
        "ico", "cur",
        "jp2", "j2k", "jpf", "jpx",
        "jxl"
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
        case "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp": "image/jpeg"
        case "png", "apng": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heics": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "bmp", "dib": "image/bmp"
        case "svg", "svgz": "image/svg+xml"
        case "avif": "image/avif"
        case "jxl": "image/jxl"
        case "ico", "cur": "image/x-icon"
        case "jp2", "j2k", "jpf", "jpx": "image/jp2"
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

    /// WebP / HEIC / GIF 处理后 ImageIO 经常解不开，缩略图再要一版 JPEG。
    static func needsJPEGPreview(key: String) -> Bool {
        switch `extension`(of: key) {
        case "webp", "heic", "heif", "heics", "gif", "avif":
            true
        default:
            false
        }
    }

    /// Aliyun IMG can decode these for `x-oss-process`. SVG / ICO 等只能当对象存。
    static func imgProcessable(key: String) -> Bool {
        switch `extension`(of: key) {
        case "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp",
             "png", "apng",
             "gif",
             "webp",
             "bmp", "dib",
             "tif", "tiff",
             "heic", "heif":
            true
        default:
            false
        }
    }

    static var importTypes: [UTType] {
        var types: [UTType] = [
            .image, .jpeg, .png, .gif, .webP, .tiff, .bmp,
            .heic, .heif, .rawImage, .svg,
            .json, .text, .plainText, .folder
        ]
        if let avif = UTType("public.avif") { types.append(avif) }
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        if let svg = UTType("public.svg-image") { types.append(svg) }
        if let gif = UTType("com.compuserve.gif") { types.append(gif) }
        return types
    }

    static func pickerTypes(imagesOnly: Bool) -> [UTType] {
        imagesOnly ? importTypes : [.item, .folder]
    }
}

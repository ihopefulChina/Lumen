import Foundation

enum LinkEscaping {
    static func markdownAlt(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    static func htmlAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func markdownImage(name: String, url: String) -> String {
        "![\(markdownAlt(name))](\(url))"
    }

    static func htmlImage(name: String, url: String) -> String {
        "<img src=\"\(htmlAttribute(url))\" alt=\"\(htmlAttribute(name))\" />"
    }
}

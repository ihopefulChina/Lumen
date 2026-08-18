import Foundation

enum MCPHTTPSafety {
    static func validatedContentType(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw MCPHTTPSafetyError.invalidContentType
        }

        let mediaType = value.split(separator: ";", maxSplits: 1)[0]
        let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isHTTPTokenCharacter) }) else {
            throw MCPHTTPSafetyError.invalidContentType
        }
        return value
    }

    private static func isHTTPTokenCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber
                || "!#$%&'*+-.^_`|~".contains(character))
    }
}

enum MCPHTTPSafetyError: LocalizedError {
    case invalidContentType

    var errorDescription: String? {
        "Content-Type 格式无效；不允许换行或其他控制字符。"
    }
}

/// Signed OSS requests must never be forwarded automatically. A redirect can
/// change the signed path or origin and risk disclosing the Authorization and
/// security-token headers. The caller receives the 3xx response as an error.
final class OSSRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

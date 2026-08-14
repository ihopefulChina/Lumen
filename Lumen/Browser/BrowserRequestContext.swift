import Foundation

struct BrowserRequestContext: Equatable, Sendable {
    var token: UUID
    var accountID: UUID?
    var bucketName: String?
    var prefix: String
    var objectKey: String?
}

@MainActor
final class BrowserRequestGate {
    private var current: BrowserRequestContext?

    func begin(
        accountID: UUID?,
        bucketName: String?,
        prefix: String,
        objectKey: String?
    ) -> BrowserRequestContext {
        let context = BrowserRequestContext(
            token: UUID(),
            accountID: accountID,
            bucketName: bucketName,
            prefix: prefix,
            objectKey: objectKey
        )
        current = context
        return context
    }

    func canCommit(_ context: BrowserRequestContext) -> Bool {
        current == context
    }

    func invalidate() {
        current = nil
    }
}

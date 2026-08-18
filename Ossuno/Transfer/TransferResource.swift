import Foundation

final class SecurityScopeLease: @unchecked Sendable {
    private let url: URL
    private let isAccessing: Bool

    init?(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
        self.isAccessing = true
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

final class TransferResource: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var cleanupURLs: [URL]
    private var retainedResources: [AnyObject]
    private var onFinish: (@Sendable () -> Void)?

    init(
        cleanupURLs: [URL] = [],
        retainedResources: [AnyObject] = [],
        onFinish: @escaping @Sendable () -> Void = {}
    ) {
        self.cleanupURLs = cleanupURLs
        self.retainedResources = retainedResources
        self.onFinish = onFinish
    }

    convenience init(_ onFinish: @escaping @Sendable () -> Void) {
        self.init(onFinish: onFinish)
    }

    func finish() {
        let payload: ([URL], (@Sendable () -> Void)?)? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            let payload = (cleanupURLs, onFinish)
            cleanupURLs = []
            onFinish = nil
            retainedResources = []
            return payload
        }
        guard let (urls, callback) = payload else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        callback?()
    }

    deinit {
        finish()
    }
}

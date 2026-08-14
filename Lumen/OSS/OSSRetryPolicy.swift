import Foundation

enum OSSRetryOutcome: Equatable, Sendable {
    case httpStatus(Int)
    case urlError(URLError.Code)
}

protocol OSSRetrySleeping: Sendable {
    func sleep(for delay: Duration) async throws
}

struct TaskOSSRetrySleeper: OSSRetrySleeping {
    func sleep(for delay: Duration) async throws {
        try await Task.sleep(for: delay)
    }
}

struct OSSRetryPolicy: Sendable {
    let maxAttempts: Int
    private let jitter: @Sendable () -> Double

    init(
        maxAttempts: Int = 4,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: -0.1...0.1) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.jitter = jitter
    }

    func delay(afterAttempt attempt: Int, outcome: OSSRetryOutcome) -> Duration? {
        guard attempt > 0, attempt < maxAttempts, isRetryable(outcome) else { return nil }
        let baseMilliseconds = min(4_000, 500 * (1 << min(attempt - 1, 3)))
        let boundedJitter = min(0.2, max(-0.2, jitter()))
        let milliseconds = Int64((Double(baseMilliseconds) * (1 + boundedJitter)).rounded())
        return .milliseconds(milliseconds)
    }

    func outcome(for error: any Error) -> OSSRetryOutcome? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            return .urlError(urlError.code)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return .urlError(URLError.Code(rawValue: nsError.code))
    }

    private func isRetryable(_ outcome: OSSRetryOutcome) -> Bool {
        switch outcome {
        case .httpStatus(let status):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .urlError(let code):
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .resourceUnavailable,
                .backgroundSessionWasDisconnected
            ].contains(code)
        }
    }
}

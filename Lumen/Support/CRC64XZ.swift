import Foundation

enum CRC64XZ {
    private static let reflectedPolynomial: UInt64 = 0xC96C_5795_D787_0F42
    private static let initialValue = UInt64.max

    private static let table: [UInt64] = (0..<256).map { index in
        var value = UInt64(index)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? (value >> 1) ^ reflectedPolynomial
                : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt64 {
        var state = initialValue
        update(&state, with: data)
        return state ^ UInt64.max
    }

    static func checksum(fileURL: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var state = initialValue
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            update(&state, with: chunk)
        }
        return state ^ UInt64.max
    }

    private static func update(_ state: inout UInt64, with data: Data) {
        for byte in data {
            let index = Int((state ^ UInt64(byte)) & 0xFF)
            state = table[index] ^ (state >> 8)
        }
    }
}

struct OSSIntegrityError: LocalizedError, Sendable, Equatable {
    var localCRC64: UInt64
    var serverValue: String

    var errorDescription: String? {
        "传输完整性校验失败，本地 CRC64 与 OSS 返回值不一致"
    }

    var failureReason: String? {
        "本地：\(localCRC64)，OSS：\(serverValue)"
    }
}

import Foundation

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value = String(value.dropFirst())
        }
        if let plus = value.firstIndex(of: "+") {
            value = String(value[..<plus])
        }
        if let dash = value.firstIndex(of: "-") {
            value = String(value[..<dash])
        }
        return value
    }

    static func parts(_ raw: String) -> [Int]? {
        let value = normalized(raw)
        guard !value.isEmpty else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }
        return components.compactMap { Int($0) }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let left = parts(candidate), let right = parts(current) else { return false }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

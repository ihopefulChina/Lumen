import Foundation

struct OSSObjectTag: Equatable, Hashable, Sendable {
    var key: String
    var value: String
}

struct OSSObjectProperties: Equatable, Sendable {
    var contentType: String
    var cacheControl: String
    var contentDisposition: String
    var userMetadata: [String: String]
}

struct EditableProperty: Identifiable, Equatable, Sendable {
    var id = UUID()
    var key: String
    var value: String
}

struct ObjectPropertiesDraft: Equatable, Sendable {
    var contentType: String
    var cacheControl: String
    var contentDisposition: String
    var metadata: [EditableProperty]
    var tags: [EditableProperty]

    static let empty = ObjectPropertiesDraft(
        contentType: "",
        cacheControl: "",
        contentDisposition: "",
        metadata: [],
        tags: []
    )

    var validationErrors: [String] {
        var errors: [String] = []
        for value in [contentType, cacheControl, contentDisposition] where Self.hasNewline(value) {
            errors.append("HTTP 属性不能包含换行")
        }
        errors.append(contentsOf: Self.validate(rows: metadata, name: "元数据", maximum: nil))
        errors.append(contentsOf: Self.validate(rows: tags, name: "标签", maximum: 10))
        return Array(Set(errors)).sorted()
    }

    var isValid: Bool { validationErrors.isEmpty }

    var properties: OSSObjectProperties {
        OSSObjectProperties(
            contentType: contentType,
            cacheControl: cacheControl,
            contentDisposition: contentDisposition,
            userMetadata: Dictionary(uniqueKeysWithValues: metadata.map {
                ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.value)
            })
        )
    }

    var objectTags: [OSSObjectTag] {
        tags.map {
            OSSObjectTag(
                key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines),
                value: $0.value
            )
        }
    }

    private static func validate(
        rows: [EditableProperty],
        name: String,
        maximum: Int?
    ) -> [String] {
        var errors: [String] = []
        if let maximum, rows.count > maximum { errors.append("最多可添加 \(maximum) 个\(name)") }
        let keys = rows.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if keys.contains(where: \.isEmpty) { errors.append("\(name)键不能为空") }
        if Set(keys).count != keys.count { errors.append("\(name)键不能重复") }
        if rows.contains(where: { hasNewline($0.key) || hasNewline($0.value) }) {
            errors.append("\(name)不能包含换行")
        }
        return errors
    }

    private static func hasNewline(_ value: String) -> Bool {
        value.contains("\r") || value.contains("\n")
    }
}

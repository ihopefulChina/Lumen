import Foundation

enum CrossBucketMethod: String, Equatable, Sendable {
    case serverSide
    case relay

    var title: String { self == .serverSide ? "云端直接复制" : "通过这台 Mac 中转" }
}

struct CrossBucketMapping: Equatable, Hashable, Sendable {
    var sourceKey: String
    var destinationKey: String
    var expectedSize: Int64
}

struct CrossBucketPlan: Equatable, Sendable {
    var method: CrossBucketMethod
    var mappings: [CrossBucketMapping]
    var knownBytes: Int64
}

struct CrossBucketPreflight: Identifiable, Sendable {
    var id = UUID()
    var plan: CrossBucketPlan
    var mode: CloudOperationMode
    var sourceAccount: OSSAccount
    var sourceBucket: OSSBucket
    var destinationAccount: OSSAccount
    var destinationBucket: OSSBucket
    var sourceClient: OSSClient
    var destinationClient: OSSClient
    var overwrite: Bool
    var renamedConflicts: Int
}

enum CrossBucketOperation {
    static func method(
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        sourceRegion: String,
        destinationRegion: String
    ) -> CrossBucketMethod {
        sourceAccountID == destinationAccountID && sourceRegion == destinationRegion
            ? .serverSide
            : .relay
    }

    static func plan(
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        sourceRegion: String,
        destinationRegion: String,
        destinationPrefix: String,
        objectKeys: [String],
        folders: [String: [OSSObject]]
    ) throws -> CrossBucketPlan {
        var mappings = objectKeys.map {
            CrossBucketMapping(
                sourceKey: $0,
                destinationKey: PathTemplate.join(destinationPrefix, key: PathTemplate.lastComponent($0)),
                expectedSize: 0
            )
        }
        for prefix in folders.keys.sorted() {
            guard prefix.hasSuffix("/"), let objects = folders[prefix] else {
                throw CloudObjectOperationError.invalidPrefix
            }
            let rootName = PathTemplate.lastComponent(String(prefix.dropLast())) + "/"
            for object in objects.sorted(by: { $0.key < $1.key }) where !object.isFolderPlaceholder {
                guard object.key.hasPrefix(prefix) else {
                    throw CloudObjectOperationError.keyOutsideSource(object.key)
                }
                let relative = String(object.key.dropFirst(prefix.count))
                mappings.append(
                    CrossBucketMapping(
                        sourceKey: object.key,
                        destinationKey: PathTemplate.join(
                            PathTemplate.join(destinationPrefix, key: rootName),
                            key: relative
                        ),
                        expectedSize: object.size
                    )
                )
            }
        }
        try CloudObjectOperation.validate(mappings.map {
            CloudObjectMapping(sourceKey: $0.sourceKey, destinationKey: $0.destinationKey)
        })
        var bytes: Int64 = 0
        for mapping in mappings {
            let (sum, overflow) = bytes.addingReportingOverflow(max(0, mapping.expectedSize))
            bytes = overflow ? Int64.max : sum
        }
        return CrossBucketPlan(
            method: method(
                sourceAccountID: sourceAccountID,
                destinationAccountID: destinationAccountID,
                sourceRegion: sourceRegion,
                destinationRegion: destinationRegion
            ),
            mappings: mappings,
            knownBytes: bytes
        )
    }

    static func emptyResultMessage(hadMappings: Bool) -> String {
        hadMappings ? "所有同名项目都已跳过" : "源文件夹为空，没有可复制的对象"
    }

    static func rollbackDestinations(
        copied: [CrossBucketMapping],
        removedSources: Set<String>
    ) -> [CrossBucketMapping] {
        copied.reversed().filter { !removedSources.contains($0.sourceKey) }
    }
}

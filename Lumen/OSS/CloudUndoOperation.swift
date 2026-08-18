import Foundation

struct CloudFavoriteMove: Equatable, Sendable {
    var sourcePrefix: String
    var destinationPrefix: String
}

struct CloudUndoOperation: Equatable, Sendable {
    var accountID: UUID
    var bucketName: String
    var title: String
    var mappings: [CloudObjectMapping]
    /// Exact versions created by the completed move, keyed by destination.
    /// Undo may use these keys as sources only while every identity still
    /// matches; otherwise it must leave the cloud state untouched.
    var committedDestinationIdentities: [String: OSSObjectIdentity]
    var favoriteMoves: [CloudFavoriteMove]
    var sourceSelection: Set<String>
    var destinationSelection: Set<String>

    var hasCompleteDestinationIdentities: Bool {
        let destinationKeys = Set(mappings.map(\.destinationKey))
        guard !mappings.isEmpty,
              committedDestinationIdentities.count == destinationKeys.count,
              Set(committedDestinationIdentities.keys) == destinationKeys
        else { return false }

        return committedDestinationIdentities.values.allSatisfy { identity in
            guard !identity.etag.isEmpty,
                  identity.size >= 0,
                  let versionID = identity.versionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return false }
            return !versionID.isEmpty
                && versionID.caseInsensitiveCompare("null") != .orderedSame
        }
    }

    var inverseMappings: [CloudObjectMapping] {
        mappings.map {
            CloudObjectMapping(
                sourceKey: $0.destinationKey,
                destinationKey: $0.sourceKey
            )
        }
    }

    var inverseFavoriteMoves: [CloudFavoriteMove] {
        favoriteMoves.reversed().map {
            CloudFavoriteMove(
                sourcePrefix: $0.destinationPrefix,
                destinationPrefix: $0.sourcePrefix
            )
        }
    }
}

struct OSSDeleteMarker: Equatable, Sendable {
    var key: String
    var versionID: String
}

struct CloudDeleteUndoOperation: Equatable, Sendable {
    var accountID: UUID
    var bucketName: String
    var title: String
    var markers: [OSSDeleteMarker]
    var sourceSelection: Set<String>
}

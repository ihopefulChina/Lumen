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
    var favoriteMoves: [CloudFavoriteMove]
    var sourceSelection: Set<String>
    var destinationSelection: Set<String>

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

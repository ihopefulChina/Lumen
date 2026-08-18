import Foundation
import Testing
@testable import Lumen

struct CloudUndoOperationTests {
    @Test func inverseMappingsSwapEveryExactObjectKey() {
        let operation = Self.operation(mappings: [
            CloudObjectMapping(
                sourceKey: "素材/封面 2x.png",
                destinationKey: "归档/素材/封面 2x.png"
            ),
            CloudObjectMapping(
                sourceKey: "素材/子目录/a+b.txt",
                destinationKey: "归档/素材/子目录/a+b.txt"
            )
        ])

        #expect(operation.inverseMappings == [
            CloudObjectMapping(
                sourceKey: "归档/素材/封面 2x.png",
                destinationKey: "素材/封面 2x.png"
            ),
            CloudObjectMapping(
                sourceKey: "归档/素材/子目录/a+b.txt",
                destinationKey: "素材/子目录/a+b.txt"
            )
        ])
    }

    @Test func inverseFavoriteMovesReverseOrderAndDirection() {
        let operation = Self.operation(favoriteMoves: [
            CloudFavoriteMove(sourcePrefix: "素材/", destinationPrefix: "归档/素材/"),
            CloudFavoriteMove(sourcePrefix: "图像/", destinationPrefix: "归档/图像/")
        ])

        #expect(operation.inverseFavoriteMoves == [
            CloudFavoriteMove(sourcePrefix: "归档/图像/", destinationPrefix: "图像/"),
            CloudFavoriteMove(sourcePrefix: "归档/素材/", destinationPrefix: "素材/")
        ])
    }

    @Test func operationPreservesScopeTitleAndExactSelections() {
        let accountID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let operation = CloudUndoOperation(
            accountID: accountID,
            bucketName: "设计-assets",
            title: "撤销移动",
            mappings: [],
            committedDestinationIdentities: [:],
            favoriteMoves: [],
            sourceSelection: ["素材/", "顶层 文件.txt"],
            destinationSelection: ["归档/素材/", "归档/顶层 文件.txt"]
        )

        #expect(operation.accountID == accountID)
        #expect(operation.bucketName == "设计-assets")
        #expect(operation.title == "撤销移动")
        #expect(!operation.hasCompleteDestinationIdentities)
        #expect(operation.sourceSelection == ["素材/", "顶层 文件.txt"])
        #expect(operation.destinationSelection == ["归档/素材/", "归档/顶层 文件.txt"])
    }

    private static func operation(
        mappings: [CloudObjectMapping] = [],
        favoriteMoves: [CloudFavoriteMove] = []
    ) -> CloudUndoOperation {
        let identities = Dictionary(uniqueKeysWithValues: mappings.map {
            (
                $0.destinationKey,
                OSSObjectIdentity(
                    etag: "etag-\($0.destinationKey)",
                    versionID: "version-\($0.destinationKey)",
                    size: 1
                )
            )
        })
        return CloudUndoOperation(
            accountID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            bucketName: "bucket",
            title: "撤销移动",
            mappings: mappings,
            committedDestinationIdentities: identities,
            favoriteMoves: favoriteMoves,
            sourceSelection: ["素材/"],
            destinationSelection: ["归档/素材/"]
        )
    }
}

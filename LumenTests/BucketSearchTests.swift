import Foundation
import Testing
@testable import Lumen

struct BucketSearchTests {
    private let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func queryMatchesTheFullKeyCaseInsensitivelyAndAppliesFilters() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "hero",
            filter: BucketSearchFilter(
                kind: .images,
                minimumSize: 100,
                maximumSize: nil,
                modified: .any
            )
        )
        let object = OSSObject(
            key: "assets/Hero.PNG",
            size: 200,
            etag: "etag",
            lastModified: now,
            storageClass: "Standard"
        )

        #expect(query.matches(object, now: now))
    }

    @Test func largeQueryUsesTheExactOneHundredMegabyteBoundary() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "",
            filter: .largeObjects
        )

        #expect(query.matches(object(key: "large.bin", size: 104_857_600), now: now))
        #expect(!query.matches(object(key: "small.bin", size: 104_857_599), now: now))
    }

    @Test func recentQueryRejectsObjectsOlderThanSevenDaysAndUnknownDates() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "",
            filter: .recentObjects(days: 7)
        )
        let recent = object(key: "recent.txt", modified: now.addingTimeInterval(-6 * 86_400))
        let old = object(key: "old.txt", modified: now.addingTimeInterval(-8 * 86_400))
        let unknown = object(key: "unknown.txt", modified: nil)

        #expect(query.matches(recent, now: now))
        #expect(!query.matches(old, now: now))
        #expect(!query.matches(unknown, now: now))
    }

    @Test func folderPlaceholdersNeverAppearAsFileResults() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "folder",
            filter: .all
        )

        #expect(!query.matches(object(key: "folder/"), now: now))
    }

    @Test func cacheIdentityIncludesBucketAndEveryFilterBoundary() {
        let base = BucketSearchQuery(
            accountID: accountID,
            bucketName: "one",
            text: "hero",
            filter: .all
        )
        let otherBucket = BucketSearchQuery(
            accountID: accountID,
            bucketName: "two",
            text: "hero",
            filter: .all
        )
        let sized = BucketSearchQuery(
            accountID: accountID,
            bucketName: "one",
            text: "hero",
            filter: BucketSearchFilter(
                kind: .any,
                minimumSize: 1,
                maximumSize: 10,
                modified: .any
            )
        )

        #expect(base != otherBucket)
        #expect(base != sized)
        #expect(Set([base, otherBucket, sized]).count == 3)
    }

    private func object(
        key: String,
        size: Int64 = 1,
        modified: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> OSSObject {
        OSSObject(
            key: key,
            size: size,
            etag: "etag",
            lastModified: modified,
            storageClass: "Standard"
        )
    }
}

import Foundation
import Testing
@testable import Lumen

struct VersionHistoryTests {
    @Test func literalVersionXMLPreservesVersionsDeleteMarkersAndPagingPair() throws {
        let xml = Data("""
        <ListVersionsResult>
          <IsTruncated>true</IsTruncated>
          <NextKeyMarker>docs/report.pdf</NextKeyMarker>
          <NextVersionIdMarker>v1</NextVersionIdMarker>
          <Version><Key>docs/report.pdf</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><LastModified>2026-08-15T01:00:00.000Z</LastModified><ETag>\"e2\"</ETag><Size>42</Size><StorageClass>Standard</StorageClass></Version>
          <Version><Key>docs/report.pdf</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><LastModified>2026-08-14T01:00:00.000Z</LastModified><ETag>\"e1\"</ETag><Size>21</Size><StorageClass>IA</StorageClass></Version>
          <DeleteMarker><Key>old.txt</Key><VersionId>d1</VersionId><IsLatest>true</IsLatest><LastModified>2026-08-13T01:00:00.000Z</LastModified></DeleteMarker>
        </ListVersionsResult>
        """.utf8)

        let page = try OSSXML.versionPage(from: xml)

        #expect(page.versions.map(\.versionID) == ["v2", "v1"])
        #expect(page.versions.first?.isLatest == true)
        #expect(page.versions.first?.size == 42)
        #expect(page.deleteMarkers == [OSSDeleteMarkerVersion(key: "old.txt", versionID: "d1", isLatest: true, lastModified: ISO8601DateParser.date("2026-08-13T01:00:00.000Z"))])
        #expect(page.nextKeyMarker == "docs/report.pdf")
        #expect(page.nextVersionIDMarker == "v1")
        #expect(page.isTruncated)
    }

    @Test func historyRowsAreNewestFirstAndRestoreUsesExactIdentity() {
        let versions = [
            OSSObjectVersion(key: "a", versionID: "old", isLatest: false, lastModified: Date(timeIntervalSince1970: 1), etag: "", size: 1, storageClass: "Standard"),
            OSSObjectVersion(key: "a", versionID: "new", isLatest: true, lastModified: Date(timeIntervalSince1970: 2), etag: "", size: 2, storageClass: "Standard")
        ]
        let rows = VersionHistoryRow.rows(versions: versions, deleteMarkers: [])

        #expect(rows.map(\.versionID) == ["new", "old"])
        #expect(rows.first?.isCurrent == true)
    }
}

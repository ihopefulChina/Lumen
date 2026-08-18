import Foundation
import Testing
@testable import Lumen

struct ObjectPropertiesTests {
    @Test func tagXMLRoundTripsAllowedCharactersAndSpaces() throws {
        let data = Data("""
        <Tagging><TagSet><Tag><Key>project name</Key><Value>A+B/2026</Value></Tag><Tag><Key>stage</Key><Value>final</Value></Tag></TagSet></Tagging>
        """.utf8)
        #expect(try OSSXML.tags(from: data) == [
            OSSObjectTag(key: "project name", value: "A+B/2026"),
            OSSObjectTag(key: "stage", value: "final")
        ])
    }

    @Test func taggingDataEscapesXMLMetacharactersDefensively() {
        let encoded = String(decoding: OSSXML.taggingData([OSSObjectTag(key: "a<b", value: "x&y")]), as: UTF8.self)
        #expect(encoded.contains("a&lt;b"))
        #expect(encoded.contains("x&amp;y"))
    }

    @Test func propertyDraftRejectsHeaderInjectionDuplicateKeysAndTooManyTags() {
        var draft = ObjectPropertiesDraft.empty
        draft.contentType = "text/plain\r\nInjected: yes"
        draft.metadata = [
            EditableProperty(key: "Owner", value: "A"),
            EditableProperty(key: "owner", value: "B")
        ]
        draft.tags = (0..<11).map { EditableProperty(key: "k\($0)", value: "v") }

        #expect(!draft.validationErrors.isEmpty)
        #expect(!draft.isValid)
    }

    @MainActor
    @Test func metadataThenTagsStayBoundToTheCommittedVersionAndPreserveProperties() async throws {
        let transport = ObjectPropertiesTransport(copyVersionID: "v2")
        var savedCount = 0
        let model = Self.model(transport: transport) { savedCount += 1 }
        await model.load()

        model.draft.contentType = "application/json"
        model.draft.cacheControl = "max-age=42"
        model.draft.contentDisposition = "attachment; filename=updated.json"
        model.draft.metadata = [EditableProperty(key: "owner", value: "new")]
        model.draft.tags = [EditableProperty(key: "stage", value: "final")]

        #expect(await model.save())
        #expect(savedCount == 1)
        let headers = await transport.committedCopyHeaders
        #expect(headers?["x-oss-copy-source"]?.contains("versionId=v1") == true)
        #expect(headers?["x-oss-object-acl"] == "private")
        #expect(headers?["x-oss-storage-class"] == "Standard")
        #expect(headers?["x-oss-server-side-encryption"] == "KMS")
        #expect(headers?["x-oss-server-side-encryption-key-id"] == "kms-key")
        #expect(headers?["x-oss-server-side-data-encryption"] == "SM4")
        #expect(headers?["Content-Encoding"] == "br")
        #expect(headers?["Content-Language"] == "zh-CN")
        #expect(headers?["Expires"] == "Wed, 21 Oct 2026 07:28:00 GMT")
        #expect(headers?["x-oss-tagging-directive"] == "Replace")
        #expect(headers?["x-oss-tagging"] == "old=1")
        let tagQueries = await transport.taggingWriteQueries
        #expect(tagQueries.count == 1)
        #expect(tagQueries[0].contains("tagging"))
        #expect(tagQueries[0].contains("versionId=v2"))
    }

    @MainActor
    @Test func missingCommittedMetadataVersionNeverWritesTagsToTheCurrentObject() async {
        let transport = ObjectPropertiesTransport(copyVersionID: nil)
        let model = Self.model(transport: transport) {}
        await model.load()

        model.draft.contentType = "application/json"
        model.draft.tags = [EditableProperty(key: "stage", value: "final")]

        #expect(await model.save() == false)
        #expect(model.errorMessage != nil)
        #expect(await transport.taggingWriteQueries.isEmpty)
    }

    @MainActor
    @Test func unversionedBucketLoadsPropertiesButDisablesUnsafeSave() async {
        let transport = ObjectPropertiesTransport(copyVersionID: nil)
        let model = Self.model(
            transport: transport,
            versioningStatus: .disabled
        ) {}
        await model.load()

        model.draft.contentType = "application/json"
        #expect(model.draft.contentType == "application/json")
        #expect(model.canSave == false)
        #expect(model.saveUnavailableMessage?.contains("已开启版本控制") == true)
        #expect(await transport.committedCopyHeaders == nil)
    }

    @MainActor
    private static func model(
        transport: ObjectPropertiesTransport,
        versioningStatus: OSSBucketVersioningStatus = .enabled,
        onSaved: @escaping @MainActor () -> Void
    ) -> ObjectPropertiesModel {
        let client = OSSClient(
            credentials: OSSCredentials(
                accessKeyId: "test",
                accessKeySecret: "secret",
                securityToken: nil
            ),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport,
            testingVersioningStatusOverride: versioningStatus
        )
        return ObjectPropertiesModel(
            object: OSSObject(
                key: "properties.txt",
                size: 4,
                etag: "same-etag",
                lastModified: nil,
                storageClass: "Standard"
            ),
            client: client,
            onSaved: onSaved
        )
    }
}

private actor ObjectPropertiesTransport: OSSHTTPTransport {
    private let copyVersionID: String?
    private var didCopy = false
    private var didWriteTags = false
    private(set) var committedCopyHeaders: [String: String]?
    private(set) var taggingWriteQueries: [String] = []

    init(copyVersionID: String?) {
        self.copyVersionID = copyVersionID
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let query = request.url?.query ?? ""
        if request.httpMethod == "HEAD" {
            return .init(
                status: 200,
                headers: headHeaders,
                data: Data(),
                temporaryDownloadURL: nil
            )
        }
        if query.contains("acl") {
            return .init(
                status: 200,
                headers: [:],
                data: Data(
                    "<AccessControlPolicy><AccessControlList><Grant>private</Grant></AccessControlList></AccessControlPolicy>".utf8
                ),
                temporaryDownloadURL: nil
            )
        }
        if query.contains("tagging"), request.httpMethod == "GET" {
            let tags = didWriteTags
                ? [OSSObjectTag(key: "stage", value: "final")]
                : [OSSObjectTag(key: "old", value: "1")]
            return .init(
                status: 200,
                headers: [:],
                data: OSSXML.taggingData(tags),
                temporaryDownloadURL: nil
            )
        }
        if query.contains("tagging"), request.httpMethod == "PUT" {
            taggingWriteQueries.append(query)
            didWriteTags = true
            return .init(status: 200, headers: [:], data: Data(), temporaryDownloadURL: nil)
        }
        if request.httpMethod == "PUT",
           request.value(forHTTPHeaderField: "x-oss-copy-source") != nil {
            committedCopyHeaders = request.allHTTPHeaderFields
            didCopy = true
            return .init(
                status: 200,
                headers: copyVersionID.map { ["x-oss-version-id": $0] } ?? [:],
                data: Data("<CopyObjectResult><ETag>\"same-etag\"</ETag></CopyObjectResult>".utf8),
                temporaryDownloadURL: nil
            )
        }
        return .init(
            status: 400,
            headers: [:],
            data: Data("<Error><Code>UnexpectedRequest</Code></Error>".utf8),
            temporaryDownloadURL: nil
        )
    }

    private var headHeaders: [String: String] {
        [
            "Content-Type": didCopy ? "application/json" : "text/plain",
            "Content-Length": "4",
            "ETag": "\"same-etag\"",
            "x-oss-version-id": didCopy ? (copyVersionID ?? "v2") : "v1",
            "x-oss-storage-class": "Standard",
            "Cache-Control": didCopy ? "max-age=42" : "max-age=1",
            "Content-Disposition": didCopy
                ? "attachment; filename=updated.json"
                : "inline",
            "Content-Encoding": "br",
            "Content-Language": "zh-CN",
            "Expires": "Wed, 21 Oct 2026 07:28:00 GMT",
            "x-oss-server-side-encryption": "KMS",
            "x-oss-server-side-encryption-key-id": "kms-key",
            "x-oss-server-side-data-encryption": "SM4",
            "x-oss-meta-owner": didCopy ? "new" : "old"
        ]
    }
}

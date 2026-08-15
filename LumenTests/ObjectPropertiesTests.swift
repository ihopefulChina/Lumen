import Foundation
import Testing
@testable import Lumen

struct ObjectPropertiesTests {
    @Test func tagXMLRoundTripsEncodedSpacesAndEscapesSpecialCharacters() throws {
        let data = Data("""
        <Tagging><TagSet><Tag><Key>project name</Key><Value>A&amp;B</Value></Tag><Tag><Key>stage</Key><Value>final</Value></Tag></TagSet></Tagging>
        """.utf8)
        #expect(try OSSXML.tags(from: data) == [
            OSSObjectTag(key: "project name", value: "A&B"),
            OSSObjectTag(key: "stage", value: "final")
        ])
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
}

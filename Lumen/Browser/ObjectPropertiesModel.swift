import Foundation
import Observation

@MainActor
@Observable
final class ObjectPropertiesModel {
    let object: OSSObject
    var draft = ObjectPropertiesDraft.empty
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var tagsUnavailable = false
    private var original = ObjectPropertiesDraft.empty
    private let client: OSSClient
    private let onSaved: @MainActor () -> Void

    init(object: OSSObject, client: OSSClient, onSaved: @escaping @MainActor () -> Void) {
        self.object = object
        self.client = client
        self.onSaved = onSaved
    }

    var canSave: Bool { !isLoading && !isSaving && draft.isValid && draft != original }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let head = try await client.head(key: object.key)
            let tags: [OSSObjectTag]
            do {
                tags = try await client.getObjectTags(key: object.key)
                tagsUnavailable = false
            } catch {
                tags = []
                tagsUnavailable = true
            }
            let loaded = ObjectPropertiesDraft(
                contentType: head.contentType ?? "",
                cacheControl: head.cacheControl ?? "",
                contentDisposition: head.contentDisposition ?? "",
                metadata: head.userMetadata.sorted(by: { $0.key < $1.key }).map {
                    EditableProperty(key: $0.key, value: $0.value)
                },
                tags: tags.map { EditableProperty(key: $0.key, value: $0.value) }
            )
            draft = loaded
            original = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        errorMessage = nil
        do {
            if draft.properties != original.properties {
                try await client.replaceMetadata(key: object.key, properties: draft.properties)
                // Track what actually reached the cloud, so a later failure
                // doesn't pretend the metadata edit never happened.
                original.contentType = draft.contentType
                original.cacheControl = draft.cacheControl
                original.contentDisposition = draft.contentDisposition
                original.metadata = draft.metadata
            }
            if !tagsUnavailable, draft.tags != original.tags {
                try await client.putObjectTags(key: object.key, tags: draft.objectTags)
                original.tags = draft.tags
            }
            original = draft
            onSaved()
            isSaving = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
            return false
        }
    }
}

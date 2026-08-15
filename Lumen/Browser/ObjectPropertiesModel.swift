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
            async let headRequest = client.head(key: object.key)
            async let tagsRequest = client.getObjectTags(key: object.key)
            let (head, tags) = try await (headRequest, tagsRequest)
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
            }
            if draft.objectTags != original.objectTags {
                try await client.putObjectTags(key: object.key, tags: draft.objectTags)
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

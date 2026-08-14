import Foundation
import Testing
@testable import Lumen

@MainActor
struct BrowserRenameSessionTests {
    @Test func fileRenameSelectsOnlyTheLastExtensionStem() {
        let session = BrowserRenameSession(
            key: "photo.final.png",
            name: "photo.final.png",
            kind: .object
        )

        #expect(session.initialSelection == NSRange(location: 0, length: 11))
    }

    @Test func extensionlessFileAndFolderSelectTheirWholeNames() {
        let file = BrowserRenameSession(key: "README", name: "README", kind: .object)
        let folder = BrowserRenameSession(key: "素材/", name: "素材", kind: .folder)

        #expect(file.initialSelection == NSRange(location: 0, length: 6))
        #expect(folder.initialSelection == NSRange(location: 0, length: 2))
    }

    @Test func fileSelectionRangeUsesAppKitUTF16Offsets() {
        let session = BrowserRenameSession(
            key: "图📷.png",
            name: "图📷.png",
            kind: .object
        )

        #expect(session.initialSelection == NSRange(location: 0, length: 3))
    }

    @Test func renameRequiresExactlyOneVisibleSelection() {
        let model = Self.model()
        #expect(!model.beginRenaming())

        model.replaceSelection(["a.txt", "b.txt"])
        #expect(!model.beginRenaming())

        model.replaceSelection(["a.txt"])
        #expect(model.beginRenaming())
        #expect(model.renameSession?.key == "a.txt")
        #expect(model.renameSession?.kind == .object)
    }

    @Test func requestedVisibleKeyBecomesTheOnlyRenameSelection() {
        let model = Self.model()
        model.replaceSelection(["a.txt", "b.txt"])

        #expect(model.beginRenaming(key: "folder/"))

        #expect(model.selectedKeys == ["folder/"])
        #expect(model.renameSession?.kind == .folder)
        #expect(model.renameSession?.draft == "folder")
    }

    @Test func loadingBrowserCannotStartRename() {
        let model = Self.model()
        model.replaceSelection(["a.txt"])
        model.isLoading = true

        #expect(!model.beginRenaming())
        #expect(model.renameSession == nil)
    }

    @Test func renameDraftAndCommittingStateAreExplicit() {
        let model = Self.model()
        model.replaceSelection(["a.txt"])
        #expect(model.beginRenaming())

        model.updateRenameDraft("renamed.txt")
        model.setRenameCommitting(true)

        #expect(model.renameSession?.draft == "renamed.txt")
        #expect(model.renameSession?.isCommitting == true)
        model.setRenameCommitting(false)
        #expect(model.renameSession?.isCommitting == false)
    }

    @Test func selectingAnotherItemCancelsRename() {
        let model = Self.model()
        model.replaceSelection(["a.txt"])
        #expect(model.beginRenaming())

        model.select(key: "b.txt", modifiers: [])

        #expect(model.renameSession == nil)
        #expect(model.selectedKeys == ["b.txt"])
    }

    @Test func filteringOutTheTargetCancelsRename() {
        let model = Self.model()
        model.replaceSelection(["a.txt"])
        #expect(model.beginRenaming())

        model.searchText = "b"

        #expect(model.renameSession == nil)
    }

    @Test func cancelAndFinishBothEndTheSession() {
        let model = Self.model()
        model.replaceSelection(["a.txt"])
        #expect(model.beginRenaming())
        model.cancelRenaming()
        #expect(model.renameSession == nil)

        #expect(model.beginRenaming())
        model.finishRenaming()
        #expect(model.renameSession == nil)
    }

    private static func model() -> BrowserModel {
        let suite = "LumenTests.BrowserRenameSession.\(UUID().uuidString)"
        let model = BrowserModel(defaults: UserDefaults(suiteName: suite)!)
        model.folders = [OSSFolder(prefix: "folder/")]
        model.objects = [
            OSSObject(key: "a.txt", size: 1, etag: "a", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "b.txt", size: 1, etag: "b", lastModified: nil, storageClass: "Standard")
        ]
        model.imagesOnly = false
        return model
    }
}

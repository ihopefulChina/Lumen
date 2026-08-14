# Lumen 0.0.5 Finder Editing and Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lumen 0.0.5 with safe visible-only selection, Finder-style inline rename, native Mac keyboard behavior, and a verified Sparkle upgrade from the public 0.0.4 release.

**Architecture:** `BrowserModel` owns the visible-selection invariant and a pure `BrowserRenameSession`; the SwiftUI browser renders one AppKit-backed rename field in either view mode, while `AppModel` remains the OSS operation boundary and reports rename success. The existing Sparkle, DMG, appcast, and GitHub Release pipeline stays intact and is advanced to version 0.0.5/build 5.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, Xcode 26, Sparkle 2.9.2, zsh, GitHub CLI.

## Global Constraints

- Target Apple Silicon and macOS 15 or later.
- Keep the public app non-sandboxed for 0.0.3/0.0.4 data-path compatibility.
- Keep Sparkle exactly at 2.9.2 and the feed URL exactly `https://github.com/ihopefulChina/Lumen/releases/latest/download/appcast.xml`.
- Never allow a hidden selection to reach delete, download, copy, move, drag, or inspector actions.
- Never silently overwrite an OSS object during rename.
- Keep `⌘O` assigned to upload; use Return for rename and `⌘↓` for open.
- Do not change any application icon bitmap, canvas size, or subject size.
- Package version `0.0.5`, build `5`, with assets named `Lumen-0.0.5.dmg` and `appcast.xml`.
- Every Xcode command that resolves Swift packages must pass `-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -packageAuthorizationProvider netrc`.
- Preserve unrelated user changes and never expose OSS credentials or the Sparkle private key.

---

### Task 1: Enforce Visible-Only Selection

**Files:**
- Modify: `Lumen/Browser/BrowserModel.swift`
- Modify: `Lumen/App/AppModel.swift`
- Test: `LumenTests/BrowserModelTests.swift`

**Interfaces:**
- Produces: `BrowserModel.actionableSelectionKeys: Set<String>` and a private `reconcileVisibleState()` invariant used after every visibility change.
- Preserves: `select(key:modifiers:)`, `replaceSelection(_:)`, `selectedObjects`, and `selectedFolders` as the public selection API.

- [ ] **Step 1: Write failing tests for hidden and retained selection**

Add tests that name the concrete regressions:

```swift
@Test func searchRemovesHiddenSelectionFocusAndAnchor() {
    let model = Self.model()
    model.select(key: "a.txt", modifiers: [])

    model.searchText = "b"

    #expect(model.selectedKeys.isEmpty)
    #expect(model.focusedKey == nil)
    #expect(model.selectionAnchorKey == nil)
    #expect(model.selectedObjects.isEmpty)
    #expect(model.actionableSelectionKeys.isEmpty)
}

@Test func searchKeepsASelectionThatRemainsVisible() {
    let model = Self.model()
    model.select(key: "b.txt", modifiers: [])

    model.searchText = "b"

    #expect(model.selectedKeys == ["b.txt"])
    #expect(model.focusedKey == "b.txt")
}

@Test func navigatingToAnotherFolderClearsTheFolderSearch() {
    let model = Self.model()
    model.searchText = "b"

    model.navigate(to: "folder/")

    #expect(model.searchText.isEmpty)
    #expect(model.selectedKeys.isEmpty)
}
```

Also cover `imagesOnly = true` removing a selected unsupported object and `apply(_:)` removing a selected key absent from the new listing.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v005-selection \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/BrowserModelTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: the new search/navigation/filter assertions fail because `searchText`, `imagesOnly`, and direct prefix changes do not reconcile selection.

- [ ] **Step 3: Implement the model invariant and action boundary**

In `BrowserModel`:

- Make `selectedKeys`, `focusedKey`, and `selectionAnchorKey` externally read-only.
- Add observers to `searchText` and `imagesOnly` that call `reconcileVisibleState()`.
- Clear search and selection when `prefix` changes.
- Derive `selectedObjects` and `selectedFolders` from `visibleObjects` and `visibleFolders`.
- Add `actionableSelectionKeys = selectedKeys.intersection(visibleKeys)`.
- Have `apply(_:)` call the same reconciliation method instead of carrying a second implementation.

Update the existing `primaryObjectUsesVisibleOrderEvenWhenFolderIsSelected` test to call `replaceSelection(["folder/", "b.txt", "c.txt"])` instead of assigning the now read-only selection property.

In `AppModel`, use `actionableSelectionKeys` in `requestDeleteSelection()`, `deleteSelection()`, and cloud payload creation so a future invariant regression cannot act on a hidden key.

- [ ] **Step 4: Run focused and related tests and verify GREEN**

Run the Task 1 command, then:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v005-selection-related \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/BrowserModelTests \
  -only-testing:LumenTests/OSSClientTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: both suites pass and no compiler warning is introduced.

- [ ] **Step 5: Commit the invariant fix**

```bash
git add Lumen/Browser/BrowserModel.swift Lumen/App/AppModel.swift LumenTests/BrowserModelTests.swift
git commit -m "fix: prevent actions on filtered OSS items"
```

### Task 2: Model a Finder Rename Session

**Files:**
- Create: `Lumen/Browser/BrowserRenameSession.swift`
- Modify: `Lumen/Browser/BrowserModel.swift`
- Test: `LumenTests/BrowserRenameSessionTests.swift`

**Interfaces:**
- Produces: `BrowserRenameSession`, `BrowserRenameKind`, `beginRenaming(key:) -> Bool`, `updateRenameDraft(_:)`, `setRenameCommitting(_:)`, `cancelRenaming()`, and `finishRenaming()`.
- Consumes: current visible folders, objects, selection, loading state, and selection focus from `BrowserModel`.

- [ ] **Step 1: Write failing pure-state tests**

Create tests with literal expected UTF-16 ranges:

```swift
@Test func fileRenameSelectsOnlyTheLastExtensionStem() {
    let session = BrowserRenameSession(
        key: "photo.final.png",
        name: "photo.final.png",
        kind: .object
    )
    #expect(session.initialSelection == NSRange(location: 0, length: 11))
}

@Test func extensionlessFileAndFolderSelectTheirWholeNames() {
    #expect(BrowserRenameSession(key: "README", name: "README", kind: .object).initialSelection == NSRange(location: 0, length: 6))
    #expect(BrowserRenameSession(key: "素材/", name: "素材", kind: .folder).initialSelection == NSRange(location: 0, length: 2))
}

@Test func renameRequiresExactlyOneVisibleSelection() {
    let model = Self.model()
    #expect(!model.beginRenaming())
    model.replaceSelection(["a.txt", "b.txt"])
    #expect(!model.beginRenaming())
    model.replaceSelection(["a.txt"])
    #expect(model.beginRenaming())
    #expect(model.renameSession?.key == "a.txt")
}

@Test func cancelAndCommitStatePreserveTheDraftDeliberately() {
    let model = Self.model()
    model.replaceSelection(["a.txt"])
    #expect(model.beginRenaming())
    model.updateRenameDraft("renamed.txt")
    model.setRenameCommitting(true)
    #expect(model.renameSession?.draft == "renamed.txt")
    #expect(model.renameSession?.isCommitting == true)
    model.cancelRenaming()
    #expect(model.renameSession == nil)
}
```

Add a local `private static func model() -> BrowserModel` to the new test type with one `folder/` folder plus `a.txt`, `b.txt`, and `c.txt`, and set `imagesOnly = false`. Do not share hidden mutable state between test types.

- [ ] **Step 2: Run the rename-session tests and verify RED**

Run the same Xcode shape as Task 1 with `-only-testing:LumenTests/BrowserRenameSessionTests`.

Expected: compilation fails because the rename-session types and methods do not exist.

- [ ] **Step 3: Implement the minimal pure state**

Create:

```swift
enum BrowserRenameKind: Sendable, Equatable {
    case object
    case folder
}

struct BrowserRenameSession: Sendable, Equatable {
    let key: String
    let originalName: String
    let kind: BrowserRenameKind
    let initialSelection: NSRange
    var draft: String
    var isCommitting = false
}
```

The initializer uses `NSString.pathExtension` and `NSString.deletingPathExtension` only for `.object`; range length must use `NSString.length` so AppKit receives a UTF-16 range. Add the listed `BrowserModel` methods, reject loading and non-single-visible selection, and cancel the session when visibility or navigation removes its target.

Update `select(key:modifiers:)`, `replaceSelection(_:)`, and `clearSelection()` so a selection change away from the rename key cancels the session, while selecting the same key preserves it.

- [ ] **Step 4: Run rename and browser tests and verify GREEN**

Run `BrowserRenameSessionTests` and `BrowserModelTests` together. Expected: all pass, including selection behavior from Task 1.

- [ ] **Step 5: Commit the rename model**

```bash
git add Lumen/Browser/BrowserRenameSession.swift Lumen/Browser/BrowserModel.swift LumenTests/BrowserRenameSessionTests.swift LumenTests/BrowserModelTests.swift
git commit -m "feat: model Finder-style rename sessions"
```

### Task 3: Keep Inline Editing Open When OSS Rename Fails

**Files:**
- Modify: `Lumen/App/AppModel.swift`
- Test: `LumenTests/BrowserModelTests.swift`

**Interfaces:**
- Changes: `rename(_:to:) async -> Bool` and `renameFolder(_:to:) async -> Bool`.
- Returns: `true` for a successful or unchanged name; `false` when busy, unavailable, invalid, conflicting, incomplete, or otherwise failed.

- [ ] **Step 1: Write failing AppModel result tests**

Add a local sequential `OSSHTTPTransport` test double whose complete response steps mirror actual OSS responses. Test at least:

```swift
@Test func invalidObjectRenameReportsFailureWithoutSendingARequest() async {
    let fixture = Self.renameModel(transport: RenameTransport(steps: []))

    let succeeded = await fixture.model.rename(fixture.object, to: "nested/name")

    #expect(!succeeded)
    #expect(fixture.model.banner?.isError == true)
    #expect(await fixture.transport.requestCount == 0)
}

@Test func objectRenameConflictReportsFailureAndKeepsTheSourceSelected() async {
    let conflict = Data("<Error><Code>FileAlreadyExists</Code><Message>Exists</Message><RequestId>rename</RequestId></Error>".utf8)
    let fixture = Self.renameModel(transport: RenameTransport(steps: [
        .response(status: 409, data: conflict)
    ]))
    fixture.model.browser.replaceSelection([fixture.object.key])

    let succeeded = await fixture.model.rename(fixture.object, to: "new.txt")

    #expect(!succeeded)
    #expect(fixture.model.browser.selectedKeys == [fixture.object.key])
    #expect(await fixture.transport.methods == ["PUT"])
}
```

Add a success test with PUT 200, DELETE 204, and a final GET listing containing the renamed key; assert `true` and the new selection.

- [ ] **Step 2: Run focused tests and verify RED**

Run `-only-testing:LumenTests/BrowserModelTests`.

Expected: compilation fails because both rename functions currently return `Void`.

- [ ] **Step 3: Return explicit success without changing safety order**

Change every guard/catch path to `return false`, the unchanged destination path to `return true`, and the completed network path to `return true`. Keep `overwrite: false`, refresh-before-new-selection, favorite prefix replacement, and copy-before-delete behavior unchanged.

- [ ] **Step 4: Run AppModel, OSS client, and cloud operation tests**

Run `BrowserModelTests`, `OSSClientTests`, and `SafetyAndVersionTests`. Expected: pass with the existing conflict test still proving no DELETE follows a failed PUT.

- [ ] **Step 5: Commit result-aware rename operations**

```bash
git add Lumen/App/AppModel.swift LumenTests/BrowserModelTests.swift
git commit -m "fix: preserve rename context after OSS failures"
```

### Task 4: Render Inline Rename and Native Keyboard Behavior

**Files:**
- Create: `Lumen/Views/FinderRenameField.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/LumenApp.swift`
- Test: `LumenTests/FinderRenameFieldTests.swift`

**Interfaces:**
- Produces: `FinderRenameField(text:initialSelection:alignment:isCommitting:onCommit:onCancel:)`.
- Consumes: `BrowserModel.renameSession` and the Boolean return values from Task 3.
- Adds: `LumenActions.rename` and `LumenActions.openSelection`.

- [ ] **Step 1: Write failing command-routing tests for the real AppKit coordinator**

Expose the coordinator at module scope for `@testable` access and test real selector routing:

```swift
@MainActor
@Test func renameCoordinatorRoutesReturnToCommit() {
    var commits = 0
    let coordinator = FinderRenameCoordinator(onCommit: { commits += 1 }, onCancel: {})
    let handled = coordinator.handleCommand(#selector(NSResponder.insertNewline(_:)))
    #expect(handled)
    #expect(commits == 1)
}

@MainActor
@Test func renameCoordinatorRoutesEscapeToCancel() {
    var cancellations = 0
    let coordinator = FinderRenameCoordinator(onCommit: {}, onCancel: { cancellations += 1 })
    let handled = coordinator.handleCommand(#selector(NSResponder.cancelOperation(_:)))
    #expect(handled)
    #expect(cancellations == 1)
}
```

Also assert an unrelated selector returns `false`, so normal text editing remains AppKit-owned.

- [ ] **Step 2: Run the coordinator tests and verify RED**

Run `-only-testing:LumenTests/FinderRenameFieldTests`.

Expected: compilation fails because the coordinator does not exist.

- [ ] **Step 3: Build the AppKit-backed rename field**

Implement an `NSViewRepresentable` around `NSTextField` with an `NSTextFieldDelegate`. It must:

- use the system control size, centered text in grid and leading text in table;
- become first responder once per session and apply `initialSelection` to the field editor;
- forward text changes through the binding;
- route newline and cancel selectors through the tested coordinator;
- refresh coordinator closures and alignment from the current SwiftUI value during `updateNSView`;
- disable editing while `isCommitting` without resigning focus;
- avoid animations, delays, and custom key handling inside the field.

- [ ] **Step 4: Replace the rename Alert with inline cells**

Remove `BrowserRenameTarget`, `renameTarget`, `renameText`, and the `.alert("重命名", ...)` block from `BrowserView`.

Render `FinderRenameField` in the existing folder, asset, and table name positions when the row key matches `renameSession.key`. Use one binding backed by `updateRenameDraft(_:)`. Context-menu rename must select the clicked item, yield once for the menu to close, then call `beginRenaming(key:)`.

On commit, set committing state, call the matching `AppModel` function, and finish the session only on `true`; on `false`, reset committing and return focus to the field. Keep the existing double-click handlers unchanged.

- [ ] **Step 5: Wire Finder keyboard semantics**

In `RootView`:

- when Return has no modifiers and no text editor is active, call `beginRenaming()` unless cloud organization is busy;
- when Esc is pressed, cancel rename before clearing selection;
- when `⌘↓` is pressed, call the existing open-focused-item logic;
- continue to pass every key event through when an `NSTextView` field editor is first responder.

Add `rename` and `openSelection` to `LumenActions`, expose “重命名” and “打开选中项” in the Browse menu, and keep `⌘O` upload unchanged.

- [ ] **Step 6: Build and run focused tests**

Run `FinderRenameFieldTests`, `BrowserRenameSessionTests`, and `BrowserModelTests`, then run a Debug build. Expected: all pass, no Swift concurrency or AppKit delegate warnings.

- [ ] **Step 7: Commit inline editing**

```bash
git add Lumen/Views/FinderRenameField.swift Lumen/Views/BrowserView.swift Lumen/Views/RootView.swift Lumen/LumenApp.swift LumenTests/FinderRenameFieldTests.swift
git commit -m "feat: rename OSS items inline like Finder"
```

### Task 5: Prepare Version, Updater UX, README, and Release Notes

**Files:**
- Modify: `Lumen/Views/SettingsView.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Modify: `scripts/package-dmg.sh`
- Modify: `README.md`
- Create: `docs/releases/v0.0.5.md`
- Create: `docs/superpowers/checklists/2026-08-15-lumen-v0.0.5-release.md`

**Interfaces:**
- Preserves: `AppUpdater.feedURL` and Sparkle public key.
- Produces: 0.0.5/build 5 metadata and publication documentation.

- [ ] **Step 1: Improve the updater control without changing the update engine**

Disable the settings button with `.disabled(!model.updates.canCheckForUpdates)` and add secondary copy: “发现新版本后可直接安装；Lumen 会在安装完成后自动重新打开。” This is a direct presentation of the already-tested `canCheckForUpdates` and Sparkle behavior, not a second updater.

- [ ] **Step 2: Advance build and package metadata**

Change every app and test target configuration to `MARKETING_VERSION = 0.0.5` and `CURRENT_PROJECT_VERSION = 5`. Change the package script version, build, derived-data directory, and temporary directory names from v004 to v005 while retaining every signing and safety gate.

- [ ] **Step 3: Update user-facing documentation**

Update README download URLs, version requirements, Finder interaction section, shortcut table, and automatic-update compatibility wording. Create concise release notes covering inline rename, hidden-selection protection, keyboard changes, first 0.0.4-to-0.0.5 in-app update, and system requirements.

Create a release checklist with explicit gates for selection safety, inline editing, full tests, real OSS availability, Release build/analyze, mounted DMG version/signature, Sparkle signature/feed, GitHub release state, and remote hashes.

- [ ] **Step 4: Validate metadata and prose mechanically**

Run:

```bash
rg -n '0\.0\.4|release-v004|lumen-v004' README.md scripts/package-dmg.sh Lumen.xcodeproj/project.pbxproj docs/releases/v0.0.5.md
plutil -lint Info.plist
zsh -n scripts/package-dmg.sh
git diff --check
```

Expected: only intentional historical compatibility references to 0.0.4 remain; plist, shell syntax, and whitespace checks pass.

- [ ] **Step 5: Commit release preparation**

```bash
git add Lumen/Views/SettingsView.swift Lumen.xcodeproj/project.pbxproj scripts/package-dmg.sh README.md docs/releases/v0.0.5.md docs/superpowers/checklists/2026-08-15-lumen-v0.0.5-release.md
git commit -m "docs: prepare Lumen 0.0.5 release"
```

### Task 6: Verify, Package, Integrate, and Publish v0.0.5

**Files:**
- Modify after packaging: `appcast.xml`
- Modify after packaging: `docs/releases/v0.0.5.md`
- Modify during evidence capture: `docs/superpowers/checklists/2026-08-15-lumen-v0.0.5-release.md`
- Generate ignored asset: `dist/Lumen-0.0.5.dmg`
- Generate ignored asset: `dist/appcast.xml`

**Interfaces:**
- Produces: signed appcast build 5, public GitHub v0.0.5 Latest release, and verifiable local/remote hashes.

- [ ] **Step 1: Run the clean Debug test suite**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v005-full \
  -resultBundlePath .build/test-v005-full.xcresult \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  clean test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
xcrun xcresulttool get test-results summary \
  --path .build/test-v005-full.xcresult --compact
```

Expected: zero failed tests; the real OSS smoke either passes and cleans its v005 prefix or is explicitly skipped before any write because credentials are unavailable.

- [ ] **Step 2: Run Release build and static analysis**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/analyze-v005 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  clean analyze CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: exit 0 with no project warning.

- [ ] **Step 3: Package and validate the signed update feed**

```bash
./scripts/package-dmg.sh
plutil -p .build/release-v005/Build/Products/Release/Lumen.app/Contents/Info.plist
xmllint --noout appcast.xml
shasum -a 256 dist/Lumen-0.0.5.dmg dist/appcast.xml appcast.xml
```

Confirm build 5 is the first appcast item, build 4 remains present, enclosure length equals `stat -f %z dist/Lumen-0.0.5.dmg`, and Sparkle `sign_update --verify` accepts the final DMG/signature pair.

- [ ] **Step 4: Smoke-test the packaged application**

Mount the DMG read-only in a unique `mktemp -d` directory, verify version 0.0.5/build 5 with `plutil`, run `codesign --verify --deep --strict`, launch the mounted app in a new instance, confirm no Sparkle configuration error appears, then terminate only the process started by this smoke test and detach the image.

- [ ] **Step 5: Record artifact hashes and commit final local assets**

Insert the actual DMG SHA-256 into `docs/releases/v0.0.5.md`, mark every completed local gate in the checklist, verify `git diff --check`, and commit `appcast.xml` plus documentation. Do not commit `dist/`.

```bash
git add appcast.xml docs/releases/v0.0.5.md docs/superpowers/checklists/2026-08-15-lumen-v0.0.5-release.md
git commit -m "release: finalize Lumen 0.0.5 artifacts"
```

- [ ] **Step 6: Perform a structured self-review and integrate**

Review the complete branch diff against the design spec, run the full test summary again if any code changes, and resolve every correctness, safety, accessibility, and release finding. Fast-forward the reviewed branch into `main` with a clean worktree.

- [ ] **Step 7: Tag, push, and create the public release**

```bash
git tag -a v0.0.5 -m "Lumen 0.0.5"
git push origin main
git push origin v0.0.5
gh release create v0.0.5 \
  dist/Lumen-0.0.5.dmg#'Lumen 0.0.5 for Apple Silicon' \
  dist/appcast.xml#'Sparkle update feed' \
  --repo ihopefulChina/Lumen --title 'Lumen 0.0.5' \
  --notes-file docs/releases/v0.0.5.md --latest
```

Expected: public, non-draft, non-prerelease Latest release at `/releases/tag/v0.0.5`.

- [ ] **Step 8: Verify the public 0.0.4-to-0.0.5 update path**

Download both public assets and the Latest feed into a unique temporary directory. Compare their SHA-256 values with local assets, parse the feed to prove build 5/version 0.0.5 is first and points to the v0.0.5 DMG, confirm build 4 remains, compare enclosure length, and verify the downloaded DMG with Sparkle `sign_update --verify` using the Keychain-exported signing key without printing it.

Use `gh release view v0.0.5 --json` and the GitHub repository metadata to confirm release properties and the `latest` redirect. Record the public URL, timestamps, asset sizes, and hashes in the checklist.

- [ ] **Step 9: Commit publication evidence and push**

```bash
git add docs/superpowers/checklists/2026-08-15-lumen-v0.0.5-release.md
git commit -m "docs: record Lumen 0.0.5 publication"
git push origin main
git status --short --branch
```

Expected: local `main` equals `origin/main`, the worktree is clean, and v0.0.5 remains the public Latest release.

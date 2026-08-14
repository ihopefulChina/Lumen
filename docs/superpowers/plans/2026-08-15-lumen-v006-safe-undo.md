# Lumen 0.0.6 Safe Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lumen 0.0.6 with a safe, one-level Finder-style undo for successful OSS renames and same-Bucket moves, then publish a verified Sparkle update and GitHub Release.

**Architecture:** A pure `CloudUndoOperation` stores the exact completed object and favorite-prefix mappings. `AppModel` records reversible mutations only after success, validates account/Bucket scope, and executes inverse mappings through the existing no-overwrite move path. SwiftUI exposes the model through an actionable status banner and the standard Edit-menu `⌘Z` command.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, Xcode 26, Sparkle 2.9.2, zsh, GitHub CLI.

## Global Constraints

- Target Apple Silicon and macOS 15 or later.
- Keep the public app non-sandboxed, ad-hoc signed, and unnotarized for compatibility with the established Keychain and data path.
- Keep Sparkle exactly at 2.9.2 and the feed URL exactly `https://github.com/ihopefulChina/Lumen/releases/latest/download/appcast.xml`.
- Support undo only for object rename, folder rename, and same-Bucket move. Copy, upload, create-folder, and delete remain non-undoable.
- Keep one in-memory undo level with no redo and no persistence across relaunch.
- Never overwrite an OSS object during either the forward operation or undo.
- Scope every undo operation to its exact account ID and Bucket.
- Keep the previous undo operation when an undo attempt fails; clear it only when the inverse cloud move succeeds.
- Do not change any application icon bitmap, canvas size, or subject size.
- Package version `0.0.6`, build `6`, with assets named `Lumen-0.0.6.dmg` and `appcast.xml`.
- Every Xcode command that resolves Swift packages must pass `-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -packageAuthorizationProvider netrc`.
- Preserve unrelated user changes and never expose OSS credentials or the Sparkle private key.
- The website is a separate phase and must not begin until v0.0.6 is publicly released and verified.

---

### Task 1: Model an Exact Reversible Cloud Operation

**Files:**
- Create: `Lumen/OSS/CloudUndoOperation.swift`
- Create: `LumenTests/CloudUndoOperationTests.swift`

**Interfaces:**
- Produces: `CloudFavoriteMove` and `CloudUndoOperation`.
- Derives: `inverseMappings`, `inverseFavoriteMoves`, and the original source selection without normalizing object keys.

- [ ] **Step 1: Write failing pure-model tests**

Create tests that prove exact reversal rather than reconstructing keys heuristically:

```swift
@Test func inverseMappingsSwapEveryExactObjectKey() {
    let operation = Self.operation(mappings: [
        CloudObjectMapping(sourceKey: "素材/封面 2x.png", destinationKey: "归档/素材/封面 2x.png"),
        CloudObjectMapping(sourceKey: "素材/子目录/a+b.txt", destinationKey: "归档/素材/子目录/a+b.txt")
    ])

    #expect(operation.inverseMappings == [
        CloudObjectMapping(sourceKey: "归档/素材/封面 2x.png", destinationKey: "素材/封面 2x.png"),
        CloudObjectMapping(sourceKey: "归档/素材/子目录/a+b.txt", destinationKey: "素材/子目录/a+b.txt")
    ])
}

@Test func inverseFavoriteMovesReversePrefixPairsInReverseOrder() {
    let operation = Self.operation(favoriteMoves: [
        CloudFavoriteMove(sourcePrefix: "素材/", destinationPrefix: "归档/素材/")
    ])

    #expect(operation.inverseFavoriteMoves == [
        CloudFavoriteMove(sourcePrefix: "归档/素材/", destinationPrefix: "素材/")
    ])
}
```

Also assert that source and destination selections preserve exact top-level keys and that account/Bucket/title fields survive unchanged.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-undo-model-red \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/CloudUndoOperationTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: compilation fails because the undo types do not exist.

- [ ] **Step 3: Implement the minimal pure value types**

Add Sendable, Equatable structs. Compute inverse object mappings by swapping source and destination. Compute inverse favorite mappings by reversing the operation order and swapping prefixes, so future compound prefix transformations cannot undo in the wrong order. Keep both source and destination selections as stored sets rather than deriving them from object paths.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Task 1 command again. Expected: all `CloudUndoOperationTests` pass without warnings.

- [ ] **Step 5: Commit the pure model**

```bash
git add Lumen/OSS/CloudUndoOperation.swift LumenTests/CloudUndoOperationTests.swift
git commit -m "feat: model reversible cloud operations"
```

### Task 2: Record Successful Object and Folder Renames

**Files:**
- Modify: `Lumen/App/AppModel.swift`
- Modify: `LumenTests/BrowserModelTests.swift`

**Interfaces:**
- Adds: `private(set) var lastCloudUndoOperation: CloudUndoOperation?`.
- Changes: successful object and folder rename paths record exact inverse data only after the OSS move succeeds.

- [ ] **Step 1: Add failing AppModel rename-record tests**

Extend the existing sequential `RenameResultTransport` tests:

- successful object rename records `old.txt -> new.txt`, exact source/destination selections, current account ID and Bucket, and title `撤销重命名`;
- object rename conflict leaves `lastCloudUndoOperation == nil`;
- successful folder rename lists its source prefix, moves every returned object, records all exact mappings, and records one favorite prefix mapping;
- a failed or incomplete folder listing creates no undo record.

For folder success, provide responses in the real request order: list source prefix, HEAD each destination, PUT each object, DELETE each source, and final folder refresh.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-record-rename-red \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/BrowserModelTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: compilation fails because `lastCloudUndoOperation` does not exist.

- [ ] **Step 3: Record object rename after complete success**

Add the observable, externally read-only property. In `rename(_:to:)`, keep the existing validation and `overwrite: false` call. After the forward OSS operation succeeds, create one `CloudObjectMapping`, refresh, select the destination if visible, then store the undo operation. Do not change or clear the prior undo record on validation, conflict, cancellation, or network failure.

- [ ] **Step 4: Expose and record exact folder mappings**

Replace the `movePrefix` convenience call in `renameFolder(_:to:)` with:

```swift
let mappings = try await client.prefixMappings(from: folder.prefix, to: destination)
try await client.performCloudOperation(mappings, mode: .move)
```

Use the same mappings for the undo record. Update favorites only after the move succeeds and record the corresponding `CloudFavoriteMove`. Preserve the existing incomplete-listing cancellation and no-overwrite behavior.

- [ ] **Step 5: Run focused and OSS safety tests and verify GREEN**

Run the Task 2 command, then:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-record-rename-related \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/BrowserModelTests \
  -only-testing:LumenTests/OSSClientTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: rename recording tests and existing operation rollback/conflict tests pass.

- [ ] **Step 6: Commit rename recording**

```bash
git add Lumen/App/AppModel.swift LumenTests/BrowserModelTests.swift
git commit -m "feat: remember reversible OSS renames"
```

### Task 3: Record Same-Bucket Moves and Execute Safe Undo

**Files:**
- Modify: `Lumen/App/AppModel.swift`
- Modify: `LumenTests/BrowserModelTests.swift`

**Interfaces:**
- Adds: `canUndoCloudOperation`, `undoCloudOperationTitle`, and `undoLastCloudOperation() async`.
- Changes: `.move` records the exact operation; `.copy` leaves the current undo record unchanged.

- [ ] **Step 1: Write failing move-record and scope tests**

Add tests that cover:

- successful multi-item move records exact mappings and folder favorite prefix moves;
- successful copy does not create or replace an undo record;
- `canUndoCloudOperation` is true only when the selected account and Bucket match and no cloud organization is active;
- `undoCloudOperationTitle` is the stored operation title in scope and the generic disabled title out of scope;
- calling undo in another Bucket performs zero requests and keeps the record.

- [ ] **Step 2: Write failing inverse-operation tests**

After recording an object rename, exercise undo with real transport steps:

1. HEAD the original destination and return 404;
2. PUT the renamed object back to the original key and return 200;
3. DELETE the renamed source and return 204;
4. GET the current listing and return the restored object.

Assert request methods `HEAD, PUT, DELETE, GET`, restored selection, reversed favorites, and `lastCloudUndoOperation == nil`.

Add a conflict case where HEAD returns 200. Assert that no PUT/DELETE follows, the error banner is visible, and the undo record remains available for retry.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-undo-app-red \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/BrowserModelTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: the new derived state and undo method are unavailable or fail the new assertions.

- [ ] **Step 4: Record only successful `.move` organization**

In `organizeCloud(_:to:mode:)`, retain the already computed mappings, moved folder prefixes, and destination selection. When `.move` completes, update favorites and store one undo operation with source and destination selections. When `.copy` completes, present its normal success feedback but do not modify `lastCloudUndoOperation`.

- [ ] **Step 5: Implement scoped, conflict-safe undo**

`undoLastCloudOperation()` must:

- return without network traffic when no operation exists, account/Bucket differs, or another organization is active;
- set `isOrganizingCloud` for the full cloud mutation;
- call `performCloudOperation(operation.inverseMappings, mode: .move)`;
- reverse favorite mappings only after the inverse move succeeds;
- refresh the current listing and select original source keys only when visible;
- clear the stored undo operation after cloud success, even if the subsequent listing refresh reports its normal error state;
- keep the operation and surface the OSS error when the inverse move itself fails.

- [ ] **Step 6: Run focused and related tests and verify GREEN**

Run the Task 3 command and the Task 2 related-suite command. Expected: all AppModel and OSS operation tests pass.

- [ ] **Step 7: Commit move recording and execution**

```bash
git add Lumen/App/AppModel.swift LumenTests/BrowserModelTests.swift
git commit -m "feat: undo OSS rename and move safely"
```

### Task 4: Add the Finder-Style Banner and Edit Menu Command

**Files:**
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `LumenTests/AppModelTests.swift`

**Interfaces:**
- Adds: `BannerAction.undoCloudOperation`, semantic banner action handling, and action-aware display duration.
- Extends: `LumenActions` with the current undo title, availability, and callback.
- Replaces: the default Undo/Redo command group with Lumen's scoped `⌘Z` command.

- [ ] **Step 1: Write failing semantic banner tests**

Test that an ordinary banner has no action and a 2.4-second duration, while an undo banner has `.undoCloudOperation` and a 5.5-second duration. Test that handling `.undoCloudOperation` invokes the AppModel undo path and does not merely dismiss the banner.

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-banner-red \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/AppModelTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: action and duration APIs do not exist.

- [ ] **Step 3: Implement semantic feedback without closure state**

Extend `BannerMessage` with an optional Equatable action and derived duration. Update success feedback for supported rename/move operations to include `.undoCloudOperation`. Render a distinct `撤销` button inside `BannerView`; clicking the body or close control dismisses, while clicking `撤销` dispatches the semantic action. Retain existing material, typography, motion, and Reduce Motion behavior.

- [ ] **Step 4: Add the focused Edit-menu command**

Extend `LumenActions` with `undoTitle`, `canUndo`, and `undo`. In `LumenCommands`, use `CommandGroup(replacing: .undoRedo)` and add one Button with `.keyboardShortcut("z", modifiers: .command)`. Disable it outside the matching account/Bucket or during organization. Do not expose redo.

- [ ] **Step 5: Run focused tests, all UI-adjacent tests, and analyze**

Run the Task 4 command, then:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-ui-related \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test -only-testing:LumenTests/AppModelTests \
  -only-testing:LumenTests/BrowserModelTests \
  -only-testing:LumenTests/BrowserRenameSessionTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/analyze-v006 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  analyze CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: tests pass and Analyze completes with no new warning.

- [ ] **Step 6: Commit the command and feedback UI**

```bash
git add Lumen/App/AppModel.swift Lumen/Views/RootView.swift Lumen/LumenApp.swift LumenTests/AppModelTests.swift
git commit -m "feat: expose Finder-style cloud undo"
```

### Task 5: Prepare Version 0.0.6 Documentation and Packaging

**Files:**
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Modify: `README.md`
- Create: `docs/releases/v0.0.6.md`
- Create: `docs/superpowers/checklists/2026-08-15-lumen-v0.0.6-release.md`
- Create or modify: the existing release/package script selected by repository conventions

- [ ] **Step 1: Advance every project version consistently**

Change all app/test build settings from build `5` to `6` and marketing version `0.0.5` to `0.0.6`. Confirm exactly four occurrences of each new value and zero old app version values in project settings.

- [ ] **Step 2: Update user-facing documentation**

Update README features and shortcuts with the one-level rename/move `⌘Z` behavior. State precisely that delete, copy, upload, and create-folder are not undoable. Link the new release notes, record Apple Silicon/macOS 15 requirements, and keep the existing Gatekeeper guidance honest about ad-hoc signing and lack of notarization.

Write `docs/releases/v0.0.6.md` with the safe-undo behavior, safety limits, upgrade behavior, system requirements, download filename, and public SHA placeholder represented in the checklist until packaging provides the final digest. The committed release notes themselves must not contain `TODO` or `TBD`.

- [ ] **Step 3: Prepare a deterministic v0.0.6 packaging path**

Copy the established v0.0.5 package/release script to a v0.0.6-specific path only if the repository uses versioned scripts. Update product/build numbers and output filenames without changing icon generation or resizing. Preserve the exact Sparkle signing and appcast workflow.

- [ ] **Step 4: Add a complete release checklist**

The checklist must cover clean tree, resolved Sparkle 2.9.2, full tests, Analyze, archive/build, ad-hoc signature verification, icon hash/dimension comparison against v0.0.5, DMG mount and launch, appcast signature/build ordering, git tag, GitHub Release, public redownload SHA, and Sparkle feed response.

- [ ] **Step 5: Validate the prepared metadata**

```bash
rg -n "CURRENT_PROJECT_VERSION = 6|MARKETING_VERSION = 0\.0\.6" Lumen.xcodeproj/project.pbxproj
rg -n "0\.0\.6|⌘Z|撤销" README.md docs/releases/v0.0.6.md docs/superpowers/checklists/2026-08-15-lumen-v0.0.6-release.md
git diff --check
```

Expected: four build-number matches, four marketing-version matches, accurate documentation, and no whitespace error.

- [ ] **Step 6: Commit release preparation**

```bash
git add Lumen.xcodeproj/project.pbxproj README.md docs/releases/v0.0.6.md docs/superpowers/checklists/2026-08-15-lumen-v0.0.6-release.md scripts
git commit -m "docs: prepare Lumen 0.0.6 release"
```

### Task 6: Verify, Package, and Publish v0.0.6

**Files:**
- Modify: `docs/releases/v0.0.6.md` only if the repository records the final public digest there
- Modify: `docs/superpowers/checklists/2026-08-15-lumen-v0.0.6-release.md`
- Generated outside git: `dist/Lumen-0.0.6.dmg`, `dist/appcast.xml`, archive/build products

- [ ] **Step 1: Run the full pinned test suite from a clean build directory**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/test-v006-final \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: every deterministic test passes; only the explicitly credential-gated real OSS smoke test may skip.

- [ ] **Step 2: Run final Analyze and Release build**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/release-v006 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  analyze CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/release-v006 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

- [ ] **Step 3: Package and inspect the artifact**

Run the repository's v0.0.6 release script. Verify:

```bash
codesign --verify --deep --strict --verbose=2 .build/release-v006/Build/Products/Release/Lumen.app
codesign -dv --verbose=4 .build/release-v006/Build/Products/Release/Lumen.app
shasum -a 256 dist/Lumen-0.0.6.dmg dist/appcast.xml
hdiutil verify dist/Lumen-0.0.6.dmg
```

Mount the DMG in a temporary mountpoint, confirm `CFBundleShortVersionString=0.0.6`, `CFBundleVersion=6`, arm64 architecture, Sparkle framework presence, update-feed URL, and that the packaged icon dimensions and alpha footprint match the v0.0.5 baseline. Launch the mounted app once and terminate it cleanly.

- [ ] **Step 4: Finalize appcast and release records**

Sign the DMG with the existing Sparkle EdDSA key without printing the key. Generate an appcast that lists build 6 first and retains builds 5 and 4. Record final artifact hashes and completed evidence in the release notes/checklist, then commit:

```bash
git add docs/releases/v0.0.6.md docs/superpowers/checklists/2026-08-15-lumen-v0.0.6-release.md
git commit -m "chore: record Lumen 0.0.6 release artifacts"
```

- [ ] **Step 5: Integrate and reverify main**

Merge the isolated implementation branch into `main` without rewriting user history. Run the full Task 6 test command on `main`, confirm a clean tree, and inspect the exact commits and diff intended for release.

- [ ] **Step 6: Tag, push, and publish the GitHub Release**

Create annotated tag `v0.0.6`, push `main` and the tag atomically, then publish a Latest GitHub Release using `docs/releases/v0.0.6.md` and attach exactly:

- `Lumen-0.0.6.dmg`
- `appcast.xml`

Use GitHub CLI and verify release metadata and asset sizes after upload.

- [ ] **Step 7: Verify the public update path independently**

Download both assets from the public `releases/latest/download` URLs into a fresh temporary directory. Compare SHA-256 digests against local release artifacts, inspect the public appcast for build 6 and the correct EdDSA signature, and confirm the public GitHub Release is marked Latest.

Record publication evidence in the checklist and commit/push:

```bash
git add docs/superpowers/checklists/2026-08-15-lumen-v0.0.6-release.md
git commit -m "docs: record Lumen 0.0.6 publication"
git push origin main
```

Expected final state: `main` is clean and synchronized, tag `v0.0.6` points to the release commit, the public DMG and appcast match local hashes, and v0.0.5 can discover build 6 through Sparkle.

## Post-Release Boundary

Only after Task 6 is complete, begin a separate website design specification and implementation plan. The website must use real Lumen product assets, current GitHub Release links, a restrained Mac-native visual system, responsive and accessible static HTML/CSS/JavaScript, and GitHub Pages deployment. It must not alter or republish the signed v0.0.6 application artifact.

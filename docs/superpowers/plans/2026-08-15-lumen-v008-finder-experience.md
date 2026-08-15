# Lumen 0.0.8 Finder Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Repository instructions prohibit subagent creation without separate user approval.

**Goal:** Ship Lumen 0.0.8 with a full-width Finder-like browser, on-demand information sheet, native account editor, useful Settings defaults, inherited Bucket permissions for new accounts, updated documentation, and a verified public release.

**Architecture:** Keep the existing SwiftUI/AppKit architecture and shared `AppServices`. Change small persisted behaviors in `AppSettings` and `OSSAccount`, route information presentation through the existing `AppModel`, and build the visual changes from native SwiftUI Form, sheet, toolbar, and semantic system styles. Keep release generation compatible with the existing Sparkle EdDSA update chain and strict Developer ID path.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, Xcode 26.2, Sparkle 2, shell release tooling, GitHub Actions/Pages.

## Global Constraints

- Marketing version is `0.0.8`; build number is `8`.
- macOS deployment target remains 15.0 and the release executable remains arm64-only.
- New accounts default to `ObjectACL.default`; existing persisted accounts are not migrated.
- The main browser has no persistent right inspector column.
- No new dependency, credential storage, production OSS fixture, or analytics is introduced.
- All UI uses system colors, SF text styles, SF Symbols, native controls, keyboard access, reduced motion, and light/dark mode semantics.
- Website screenshot display dimensions remain unchanged.
- Public appcast and DMG require a verified Sparkle EdDSA signature and matching byte length.

---

### Task 1: Inherited Permission and Preferred Browser View

**Files:**
- Modify: `Lumen/OSS/OSSTypes.swift`
- Modify: `Lumen/App/AppSettings.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/App/ScreenshotDemo.swift`
- Modify: `LumenTests/SafetyAndVersionTests.swift`
- Modify: `LumenTests/ScreenshotDemoTests.swift`
- Modify: `LumenTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppSettings.preferredViewMode: BrowserViewMode`.
- Produces: `AppModel.setPreferredViewMode(_:)` to update the setting and live browser session.
- Changes: `OSSAccount.prefersSignedLinks` returns true for `.default` and `.private` when no CDN domain is set.

- [ ] **Step 1: Write failing permission and settings tests**

Change the fresh-account expectation and add safe-link behavior:

```swift
@Test func aNewAccountInheritsItsBucketPermission() {
    #expect(AccountDraft.fresh().defaultACL == .default)
}

@Test func inheritedBucketPermissionUsesASignedLinkFallback() {
    let account = Self.account(defaultACL: .default)
    #expect(account.prefersSignedLinks)
}
```

Add preferred-view persistence and AppModel application tests using isolated `UserDefaults`:

```swift
@Test func preferredBrowserViewPersists() {
    let defaults = Self.defaults()
    let first = AppSettings(defaults: defaults)
    first.preferredViewMode = .list
    #expect(AppSettings(defaults: defaults).preferredViewMode == .list)
}

@Test func newWindowUsesPreferredBrowserView() {
    let defaults = Self.defaults()
    let settings = AppSettings(defaults: defaults)
    settings.preferredViewMode = .list
    let model = AppModel(services: AppServices(accounts: [], settings: settings))
    #expect(model.browser.viewMode == .list)
}
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -only-testing:LumenTests/SafetyAndVersionTests -only-testing:LumenTests/AppModelTests test
```

Expected: failures for `.private`, missing `preferredViewMode`, and current signed-link behavior.

- [ ] **Step 3: Implement inherited permission and preferred view**

Set `AccountDraft.fresh().defaultACL` and the synthetic account draft/account to `.default`. Extend `prefersSignedLinks` to include `.default`. Add a raw-string-backed `preferredViewMode` setting with Grid fallback. Apply it when `AppModel` creates a new browser, retain the focused window's mode when cloning a window, and make toolbar Grid/List changes call `setPreferredViewMode(_:)`.

- [ ] **Step 4: Run focused tests**

Run the command from Step 2. Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/OSSTypes.swift Lumen/App/AppSettings.swift Lumen/App/AppModel.swift Lumen/Views/RootView.swift Lumen/App/ScreenshotDemo.swift LumenTests/SafetyAndVersionTests.swift LumenTests/ScreenshotDemoTests.swift LumenTests/AppModelTests.swift
git commit -m "feat: inherit Bucket permissions by default"
```

### Task 2: Replace the Persistent Inspector with an Information Sheet

**Files:**
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/Views/InspectorView.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `LumenTests/AppModelTests.swift`

**Interfaces:**
- Extends: `LumenActions` with `showInfo: () -> Void`.
- Reuses: `AppModel.showInspector` as the on-demand sheet presentation binding to avoid persisted-schema churn.

- [ ] **Step 1: Write a failing action-state test**

Add a small semantic helper and test it:

```swift
@Test func informationIsAvailableOnlyInsideABucket() {
    let model = AppModel(kind: .settings, services: AppServices(accounts: []))
    #expect(!model.canShowInformation)
}
```

The helper is true when a Bucket is selected, including current-folder, object, and multi-selection contexts.

- [ ] **Step 2: Run the focused test and confirm failure**

Run:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -only-testing:LumenTests/AppModelTests test
```

Expected: compile failure because `canShowInformation` does not exist.

- [ ] **Step 3: Implement sheet presentation and keyboard command**

Remove `.inspector` and its column-width modifier from `WorkspaceView`. Attach `.sheet(isPresented: $model.showInspector)` and present `InspectorView` at a 420-point width. Change the toolbar button to set the binding true and disable it outside a Bucket. Add `showInfo` to the focused action set and a “显示信息” `Command-I` Browse menu command.

- [ ] **Step 4: Restyle `InspectorView` as native sheet content**

Use one header row with title and “完成,” a scrolling content region, native Dividers, semantic metadata rows, and a plain bottom action region. Preserve all existing object/folder/multi-selection capabilities and accessibility labels. Do not add card backgrounds, decorative blur, or a permanent pane.

- [ ] **Step 5: Run focused and screenshot fixture tests**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -only-testing:LumenTests/AppModelTests -only-testing:LumenTests/ScreenshotDemoTests test
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Views/RootView.swift Lumen/Views/InspectorView.swift Lumen/LumenApp.swift LumenTests/AppModelTests.swift
git commit -m "feat: present file information on demand"
```

### Task 3: Rebuild the Account Editor as a macOS Sheet

**Files:**
- Modify: `Lumen/Views/AccountSheet.swift`
- Modify: `LumenTests/ScreenshotDemoTests.swift`

**Interfaces:**
- Preserves: `AccountSheet(draft:)` and `AppModel.saveAccount(_:)`.
- Preserves: confirmation through `AccountACLConfirmation` for public permissions.

- [ ] **Step 1: Add fixture assertions for inherited access**

Update the synthetic account assertion:

```swift
#expect(draft.defaultACL == .default)
#expect(draft.defaultACL.title == "继承存储空间")
```

- [ ] **Step 2: Run the fixture test and confirm it fails before Task 1 behavior is present**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -only-testing:LumenTests/ScreenshotDemoTests test
```

- [ ] **Step 3: Replace the account editor layout**

Remove `NavigationStack`. Build a restrained header, grouped Form with “连接 / 存储位置 / 上传 / 高级选项,” inline error Label, and a bottom `.bar` footer containing Cancel and Add/Save. Keep field labels visible, preserve the secret reveal help label, show a lock/Keychain explanation, and use the inherited permission picker as the common path.

- [ ] **Step 4: Verify keyboard and state semantics in code**

Ensure the primary action has `.keyboardShortcut(.defaultAction)`, Cancel uses `.cancelAction`, loading disables the primary button, Escape dismisses through the cancellation action, and errors do not clear the draft.

- [ ] **Step 5: Run the fixture and safety tests**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -only-testing:LumenTests/ScreenshotDemoTests -only-testing:LumenTests/SafetyAndVersionTests test
```

- [ ] **Step 6: Commit**

```bash
git add Lumen/Views/AccountSheet.swift LumenTests/ScreenshotDemoTests.swift
git commit -m "design: refine native account setup"
```

### Task 4: Expand and Reorganize Settings

**Files:**
- Modify: `Lumen/Views/SettingsView.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `LumenTests/AppModelTests.swift`
- Modify: `LumenTests/TransferEngineTests.swift`

**Interfaces:**
- Produces: `AppModel.testAccount(_:) async throws -> Int`.
- Reuses: `TransferEngine.clearFinished()` and `TransferEngine.jobs`.

- [ ] **Step 1: Write failing connection-check and clear-history tests**

Use a recording transport/client provider to make `listBuckets()` return two synthetic Buckets, then assert:

```swift
let count = try await model.testAccount(account)
#expect(count == 2)
#expect(model.selectedAccountID == nil)
```

Add a transfer test that loads one active and one finished record, calls `clearFinished()`, and asserts only the active record remains and the journal is saved.

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -only-testing:LumenTests/AppModelTests -only-testing:LumenTests/TransferEngineTests test
```

Expected: compile failure for `testAccount`; the existing clear path test initially does not exist.

- [ ] **Step 3: Implement account connection checking**

Build an account-scoped client through `clientProvider(account, nil)`, call `listBuckets()`, and return the count without changing selection, last location, or stored account data.

- [ ] **Step 4: Build three native Settings tabs**

General contains preferred view, content filter, updates, version, and links. Transfers contains concurrency, conversion, feedback/menu-bar toggles, history count, and clear action. Accounts contains native rows, edit, async check with progress/success/error status, and Add. Keep Form grouping and semantic controls; avoid custom cards.

- [ ] **Step 5: Adjust the Settings scene size**

Set a stable width around 620 points and height around 600 points so labels do not truncate in Chinese while the window remains compact.

- [ ] **Step 6: Run focused tests**

Run the command from Step 2. Expected: all selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Lumen/Views/SettingsView.swift Lumen/App/AppModel.swift Lumen/LumenApp.swift LumenTests/AppModelTests.swift LumenTests/TransferEngineTests.swift
git commit -m "feat: expand native settings"
```

### Task 5: Version, Screenshots, README, Website, and Release Notes

**Files:**
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Modify: `scripts/package-dmg.sh`
- Modify: `README.md`
- Modify: `website/index.html`
- Modify: `website/support.html`
- Modify: `website/privacy.html`
- Modify: `website/assets/browser.png` only when the regenerated screenshot keeps the existing pixel dimensions
- Modify: `website/assets/account.png` only when the regenerated screenshot keeps the existing pixel dimensions
- Create: `docs/releases/v0.0.8.md`
- Modify: relevant version assertions in `LumenTests/*.swift`

**Interfaces:**
- Produces: version `0.0.8 (8)` in built `Info.plist`.
- Produces: `dist/Lumen-0.0.8.dmg` and a v0.0.8 appcast entry during release.

- [ ] **Step 1: Update version assertions first**

Change diagnostics and screenshot/version expectations to `0.0.8 (8)`, then run the selected tests and confirm they fail against the old project version.

- [ ] **Step 2: Update project and packaging versions**

Set every `MARKETING_VERSION` to `0.0.8`, every `CURRENT_PROJECT_VERSION` to `8`, and update package paths/names from v007 to v008 without weakening strict release checks.

- [ ] **Step 3: Update product copy**

README and website describe the full-width browser, on-demand information, inherited Bucket permission, improved account setup, preferred view, connection checks, and transfer-history controls. All latest-download links use `Lumen-0.0.8.dmg`; policy/support canonical URLs remain unchanged.

- [ ] **Step 4: Add release notes**

Write concise Chinese release notes covering the same user-visible changes and requirements: Apple Silicon and macOS 15+.

- [ ] **Step 5: Regenerate synthetic screenshots if the desktop is available**

Use `--lumen-screenshot-browser` and `--lumen-screenshot-account`; confirm the browser has no right pane, the form uses inherited permission, all identifiers are synthetic, and output pixel dimensions match the replaced assets exactly. If the Mac is locked, retain safe existing images only until capture can be performed; do not fabricate a successful screenshot audit.

- [ ] **Step 6: Validate docs and metadata**

```bash
scripts/validate-website.sh
bash -n scripts/*.sh
zsh -n scripts/*.sh
plutil -lint Info.plist Lumen/PrivacyInfo.xcprivacy
xmllint --noout appcast.xml
git diff --check
```

- [ ] **Step 7: Commit**

```bash
git add Lumen.xcodeproj/project.pbxproj scripts/package-dmg.sh README.md website docs/releases LumenTests
git commit -m "docs: prepare Lumen 0.0.8 release"
```

### Task 6: Full Verification and Publication

**Files:**
- Modify: `appcast.xml` only after the final DMG signature/length verify.
- Generate ignored artifacts: `dist/Lumen-0.0.8.dmg`, `dist/appcast.xml`.

**Interfaces:**
- Publishes: branch `agent/lumen-v008`, pull request to `main`, tag/release `v0.0.8`, website, update feed, and local `/Applications/Lumen.app`.

- [ ] **Step 1: Run full local verification**

Run the complete test suite, arm64 Release build, static analysis, website validation, shell/YAML/plist/XML validation, secret scan, and `git diff --check`. Record exact pass/skip/failure counts and output paths.

- [ ] **Step 2: Build and verify the release artifact**

Use the strict Developer ID release path when credentials exist. Otherwise match the established 0.0.7 ad-hoc application baseline without weakening the strict script, then validate DMG checksum, absence of development marker, `0.0.8 (8)`, arm64, nested code validity, Sparkle public-key match, EdDSA signature, appcast length, and exact v0.0.8 URL.

- [ ] **Step 3: Commit appcast and rerun relevant validation**

Commit only the generated tracked `appcast.xml` change after signature verification.

- [ ] **Step 4: Push and open a Draft PR**

Push `agent/lumen-v008`, create a Chinese Draft PR describing changes and evidence, wait for App and Dependency Review checks, then mark ready only when both pass.

- [ ] **Step 5: Merge and publish**

Merge to `main`, create `v0.0.8` against the merge commit, upload `Lumen-0.0.8.dmg` and `appcast.xml`, mark it latest, and verify GitHub-reported digests against local values.

- [ ] **Step 6: Verify public state**

Download the latest DMG and appcast from public URLs, verify hashes and XML values, wait for main App CI and Pages, and confirm the website renders/downloads 0.0.8.

- [ ] **Step 7: Update the local app**

Quit the installed Lumen normally, move the prior app to Trash as a recoverable backup, install the public DMG to `/Applications/Lumen.app`, launch it, and verify version `0.0.8 (8)`, code structure, executable architecture, and running process.

- [ ] **Step 8: Final evidence**

Report Release, website, PR, merge SHA, CI/Page results, test count, DMG SHA-256, installed version, recoverable backup location, and any UI screenshot inspection blocked by a locked desktop.

# Lumen 0.0.7 Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lumen 0.0.7 with safer account defaults, recoverable local state, durable retryable transfers, OSS-versioned delete undo, native help, CI/security documentation, and a fail-closed notarized release path.

**Architecture:** Pure policy and persistence types own permission confirmation, account recovery, retries, transfer journaling, delete receipts, and diagnostics. `AppModel` coordinates those services without storing credentials in journals or reports. GitHub Actions and the package script enforce the same version, build, website, signing, notarization, and appcast boundaries used for the public release.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, Xcode 26, Sparkle 2.9.2, zsh, GitHub Actions, GitHub CLI.

## Global Constraints

- Target Apple Silicon and macOS 15 or later.
- Keep Sparkle exactly at 2.9.2 and the update feed at `https://github.com/ihopefulChina/Lumen/releases/latest/download/appcast.xml`.
- Never persist or print AccessKey Secret, STS Token, signed URLs, request authorization headers, object keys in diagnostics, or the Sparkle private key.
- Default new accounts to `.private`; require explicit confirmation before saving a newly public ACL.
- Retry only transient transport failures, HTTP 408/429, and HTTP 5xx, with four total attempts.
- Restore interrupted transfers as explicit retryable failures; do not claim byte-level resume.
- Offer delete undo only for exact OSS delete-marker version IDs returned by the service.
- Keep one scoped cloud undo slot and no redo.
- Release mode must fail closed without Developer ID signing, Hardened Runtime, secure timestamp, notarization, stapling, Gatekeeper acceptance, and Sparkle signing.
- Do not change application icon bitmap dimensions or subject footprint.
- Use `apply_patch` for all source and documentation edits.
- Run real OSS smoke tests only when `REAL_OSS_SMOKE=1`; CI must not receive production credentials.

---

### Task 1: Safe Account Defaults and Recoverable Configuration

**Files:**
- Create: `Lumen/App/AccountRepository.swift`
- Modify: `Lumen/App/AccountStore.swift`
- Modify: `Lumen/App/AppServices.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/AccountSheet.swift`
- Test: `LumenTests/SafetyAndVersionTests.swift`
- Test: `LumenTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AccountRepository`, `AccountLoadResult`, `AccountRecovery`, and `AccountACLConfirmation`.
- Preserves: the existing static `AccountStore` credential and secret-account helpers.

- [ ] **Step 1: Write failing repository and ACL tests**

Add literal, file-backed tests using a unique temporary directory:

```swift
@Test func corruptPrimaryRecoversTheLastKnownGoodAccounts() throws {
    let fixture = try AccountRepositoryFixture()
    try fixture.repository.save([fixture.account])
    try fixture.repository.save([fixture.updatedAccount])
    try Data("not-json".utf8).write(to: fixture.primary)

    let loaded = fixture.repository.load()

    #expect(loaded.accounts == [fixture.account])
    #expect(loaded.recovery?.kind == .restoredBackup)
    #expect(try JSONDecoder().decode([OSSAccount].self, from: Data(contentsOf: fixture.primary)) == [fixture.account])
}

@Test func aNewAccountStartsPrivate() {
    #expect(AccountDraft.new.defaultACL == .private)
}

@Test func publicReadWriteAlwaysRequiresConfirmation() {
    #expect(AccountACLConfirmation.requiresConfirmation(from: .private, to: .publicReadWrite))
}
```

The mutation these tests catch is a corrupt primary silently becoming an empty list or a new account regressing to public access.

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS' \
  test -only-testing:LumenTests/SafetyAndVersionTests \
  -only-testing:LumenTests/AppModelTests
```

Expected: compilation fails because the repository, recovery result, ACL policy, and private draft default do not exist.

- [ ] **Step 3: Implement atomic backup and recovery**

Implement an injectable repository with `primaryURL`, `backupURL`, `FileManager`, `JSONEncoder`, and `JSONDecoder`. Before a new save, decode the existing primary; only a valid primary can replace the backup. Write encoded data atomically, read it back, and decode it before returning. On corrupt-primary/valid-backup load, move the corrupt bytes to `accounts.corrupt-<UTC timestamp>.json`, restore the backup to primary, and return `.restoredBackup`. Preserve both files and return `.unrecoverable` if neither decodes.

- [ ] **Step 4: Wire recovery state and public-ACL confirmation**

Change `AccountStore.load()` to return `AccountLoadResult`, initialize `AppServices.accounts` from `.accounts`, and expose the recovery notice to the first focused window. Change the draft default to `.private`. In `AccountSheet`, keep common ACLs in the main section, move `.publicReadWrite` into Advanced, and show a confirmation dialog before `save()` when `AccountACLConfirmation` says the change is newly public. Cancelling restores the last confirmed ACL.

- [ ] **Step 5: Verify GREEN and commit**

Run the Step 2 command, then the complete suite. Commit:

```bash
git add Lumen/App Lumen/Views/AccountSheet.swift LumenTests
git commit -m "feat: protect account configuration"
```

### Task 2: Deterministic Transient Request Retry

**Files:**
- Create: `Lumen/OSS/OSSRetryPolicy.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/OSS/OSSHTTPTransport.swift`
- Test: `LumenTests/OSSClientTests.swift`

**Interfaces:**
- Produces: `OSSRetryPolicy`, `OSSRetrySleeper`, and `OSSRetryDecision`.
- Changes: `OSSClient.send` rebuilds and re-signs a request for each allowed attempt.

- [ ] **Step 1: Write failing pure and integration tests**

```swift
@Test func retryPolicyRetriesOnlyTransientFailures() {
    let policy = OSSRetryPolicy(jitter: { 0 })
    #expect(policy.delay(afterAttempt: 1, outcome: .httpStatus(503)) == .milliseconds(500))
    #expect(policy.delay(afterAttempt: 2, outcome: .httpStatus(429)) == .seconds(1))
    #expect(policy.delay(afterAttempt: 1, outcome: .httpStatus(403)) == nil)
    #expect(policy.delay(afterAttempt: 4, outcome: .httpStatus(503)) == nil)
}

@Test func transientFailureRebuildsAndSignsTheSecondRequest() async throws {
    let transport = SequenceTransport([.response(status: 503), .response(status: 200)])
    let client = fixtureClient(transport: transport, sleeper: RecordingSleeper())
    _ = try await client.listBuckets()
    #expect(await transport.requestCount == 2)
}
```

- [ ] **Step 2: Verify RED**

Run `xcodebuild ... test -only-testing:LumenTests/OSSClientTests`. Expected: missing policy/sleeper APIs.

- [ ] **Step 3: Implement retry classification and re-signing**

Classify `URLError` connection/time/network cases, 408, 429, and 500...599 as retryable. Use delays 0.5/1/2 seconds plus injected bounded jitter, maximum four attempts. Perform cancellation checks before sleeping and before each request. Move request construction inside the attempt closure so every retry gets a new date and signature. Do not retry a body upload if the body source cannot be reopened.

- [ ] **Step 4: Verify GREEN and commit**

Run focused tests and the full suite. Commit:

```bash
git add Lumen/OSS/OSSRetryPolicy.swift Lumen/OSS/OSSClient.swift Lumen/OSS/OSSHTTPTransport.swift LumenTests/OSSClientTests.swift
git commit -m "feat: retry transient OSS requests"
```

### Task 3: Durable Transfer Journal and Relaunch Recovery

**Files:**
- Create: `Lumen/Transfer/TransferJournal.swift`
- Modify: `Lumen/Transfer/TransferJob.swift`
- Modify: `Lumen/Transfer/TransferEngine.swift`
- Modify: `Lumen/App/AppServices.swift`
- Modify: `Lumen/Views/TransferTray.swift`
- Test: `LumenTests/TransferEngineTests.swift`

**Interfaces:**
- Produces: `PersistedTransfer`, `PersistedTransferRetry`, `TransferJournalProtocol`.
- Adds: `TransferEngine.restore(from:accounts:)`, `unavailableRetryReason(_:)`, and injected journal/bookmark resolver.

- [ ] **Step 1: Write failing journal round-trip and interruption tests**

```swift
@Test func journalRoundTripContainsNoCredentialOrSignedURL() throws {
    let fixture = try TransferJournalFixture()
    try fixture.journal.save([fixture.upload])
    let bytes = try Data(contentsOf: fixture.url)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("secret-value"))
    #expect(!text.contains("Authorization"))
    #expect(try fixture.journal.load() == [fixture.upload])
}

@Test func runningJobRestoresAsRetryableInterruptedFailure() {
    let engine = TransferEngine(journal: MemoryTransferJournal(records: [.runningUpload]))
    engine.restore(accounts: [.account])
    #expect(engine.jobs.first?.status == .failed)
    #expect(engine.jobs.first?.errorMessage == "上次退出时传输中断，可重试")
    #expect(engine.canRetry(engine.jobs[0].id))
}
```

- [ ] **Step 2: Verify RED**

Run `xcodebuild ... test -only-testing:LumenTests/TransferEngineTests`. Expected: missing Codable journal and restore APIs.

- [ ] **Step 3: Implement sanitized persistence**

Make transfer enums/jobs Codable. Persist account ID, Bucket, exact object key, source/destination bookmark, options, status, byte counts, and dates. Exclude client instances, credentials, public URLs with signatures, temporary conversion paths, resources, and tasks. Save atomically after enqueue/status changes and at most once per second for progress.

- [ ] **Step 4: Restore history and exact retry descriptors**

At `AppServices.bootstrapIfNeeded`, resolve accounts and bookmarks into fresh OSS clients and retry descriptors. Convert old `.queued`/`.running` records to `.failed` with the interruption message. A missing account or stale bookmark returns a concrete unavailable reason and keeps the visible history. `clearFinished()` persists removal.

- [ ] **Step 5: Verify GREEN and commit**

Run focused tests, full tests, quit/relaunch a debug build when UI access is available, then commit:

```bash
git add Lumen/Transfer Lumen/App/AppServices.swift Lumen/Views/TransferTray.swift LumenTests/TransferEngineTests.swift
git commit -m "feat: persist recoverable transfer history"
```

### Task 4: OSS Delete-Marker Receipts and Undo

**Files:**
- Create: `Lumen/OSS/CloudDeleteUndoOperation.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/RootView.swift`
- Test: `LumenTests/OSSClientTests.swift`
- Test: `LumenTests/BrowserModelTests.swift`

**Interfaces:**
- Produces: `OSSDeleteReceipt` and `CloudDeleteUndoOperation`.
- Adds: `OSSClient.deleteObjectVersion(key:versionID:)` and a semantic cloud-undo enum covering move/rename and versioned delete.

- [ ] **Step 1: Write failing receipt parsing and exact-version tests**

```swift
@Test func deleteReturnsTheExactRecoverableMarkerReceipt() async throws {
    let transport = SequenceTransport([.response(status: 204, headers: [
        "x-oss-delete-marker": "true", "x-oss-version-id": "marker/7+exact"
    ])])
    let receipt = try await fixtureClient(transport: transport).deleteObject(key: "资料/a b.txt")
    #expect(receipt == OSSDeleteReceipt(key: "资料/a b.txt", deleteMarker: true, versionID: "marker/7+exact"))
}

@Test func undoDeletesOnlyTheReturnedMarkerVersion() async throws {
    // Seed AppModel with one delete-marker operation, run undo, then assert the
    // real captured request contains percent-encoded versionId and no object PUT.
}
```

- [ ] **Step 2: Verify RED**

Run OSS client and browser model tests. Expected: `deleteObject` returns Void and version-delete/undo types are absent.

- [ ] **Step 3: Implement receipts and version deletion**

Return headers from DELETE, preserve the exact version ID string, and add `DELETE /key?versionId=<encoded>`. Treat only marker `true` plus non-empty version ID as recoverable. Keep a partial receipt list if a later batch item fails.

- [ ] **Step 4: Integrate one-level delete undo**

Update delete confirmation text to distinguish `OSS 开启版本控制时可撤销；未开启时将永久删除`. Store delete undo only when every selected object returned a recoverable marker. `⌘Z` removes the marker versions, refreshes, restores visible selection, and clears state only after complete success. Folder delete records every exact object receipt.

- [ ] **Step 5: Verify GREEN and commit**

Run focused tests and the full suite. Commit:

```bash
git add Lumen/OSS Lumen/App/AppModel.swift Lumen/Views/RootView.swift LumenTests
git commit -m "feat: undo versioned OSS deletes"
```

### Task 5: Native Help, Redacted Diagnostics, and Accessibility

**Files:**
- Create: `Lumen/Support/DiagnosticsReport.swift`
- Create: `Lumen/Views/HelpView.swift`
- Modify: `Lumen/App/AppServices.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/Views/TransferTray.swift`
- Test: `LumenTests/SafetyAndVersionTests.swift`

**Interfaces:**
- Produces: `DiagnosticsReport.make(services:bundle:processInfo:) -> String`.
- Adds: an app-owned Help window and `复制诊断信息` command.

- [ ] **Step 1: Write a failing diagnostics redaction test**

```swift
@Test func diagnosticsExcludeStorageAndCredentialIdentifiers() {
    let report = DiagnosticsReport.make(fixture: .sensitive)
    #expect(report.contains("Lumen 0.0.7 (7)"))
    #expect(!report.contains("LTAI"))
    #expect(!report.contains("secret"))
    #expect(!report.contains("production-bucket"))
    #expect(!report.contains("private/object.jpg"))
    #expect(!report.contains("/Users/"))
}
```

- [ ] **Step 2: Verify RED, implement, and verify GREEN**

Build the report from only version/build, OS version, architecture, feed host, counts, and boolean/non-sensitive settings. Add a selectable native Help window with connection, transfer, recovery, update, shortcuts, and support sections. Route Help menu commands to the window and add external links as secondary actions. Audit icon-only controls touched by this release for accessibility labels/help and ensure status includes text.

- [ ] **Step 3: Commit**

```bash
git add Lumen/Support/DiagnosticsReport.swift Lumen/Views Lumen/App/AppServices.swift Lumen/LumenApp.swift LumenTests
git commit -m "feat: add private diagnostics and native help"
```

### Task 6: CI, Security, Privacy, Support, and Website Trust Pages

**Files:**
- Create: `.github/workflows/app.yml`
- Create: `.github/workflows/dependency-review.yml`
- Create: `.github/dependabot.yml`
- Create: `.github/ISSUE_TEMPLATE/bug.yml`
- Create: `.github/ISSUE_TEMPLATE/feature.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `SECURITY.md`
- Create: `CONTRIBUTING.md`
- Create: `website/privacy.html`
- Create: `website/support.html`
- Modify: `website/index.html`
- Modify: `website/styles.css`
- Modify: `website/sitemap.xml`
- Modify: `scripts/validate-website.sh`
- Modify: `README.md`

**Interfaces:**
- CI runs tests/build/analyze/site validation without secrets.
- Website policy pages reuse existing tokens and expose visible keyboard focus and reduced-motion behavior.

- [ ] **Step 1: Extend website validation and observe failure**

Require privacy/support files, canonical URLs, footer links, version `0.0.7`, no placeholder text, no Apple-signing caveat copy, and matching download URLs. Run `scripts/validate-website.sh`; it must fail before the new pages/version exist.

- [ ] **Step 2: Add CI and maintenance metadata**

Use `macos-15` with checkout, package resolution pinned to `Package.resolved`, full tests, Release build, `xcodebuild analyze`, website validation, `bash -n`, and `plutil -lint`. Add official `actions/dependency-review-action` for PRs and Dependabot entries for `github-actions` weekly and `swift` monthly.

- [ ] **Step 3: Add focused trust documentation and pages**

Write vulnerability reporting through GitHub private advisories, local contribution/test commands, structured bug/feature forms, a plain-language privacy policy matching `PrivacyInfo.xcprivacy`, and support guidance centered on redacted diagnostics. Reuse the existing palette/system typography and narrow document layout; add no decorative gradients or generic card grid.

- [ ] **Step 4: Verify and commit**

Run `scripts/validate-website.sh`, `bash -n scripts/*.sh`, `plutil -lint Info.plist Lumen/PrivacyInfo.xcprivacy`, and parse every workflow with Ruby YAML. Commit:

```bash
git add .github SECURITY.md CONTRIBUTING.md README.md website scripts/validate-website.sh
git commit -m "ci: add production readiness gates"
```

### Task 7: Fail-Closed Signed and Notarized Packaging

**Files:**
- Modify: `scripts/package-dmg.sh`
- Create: `scripts/verify-release.sh`
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Modify: `Info.plist`
- Create: `docs/releases/v0.0.7.md`
- Modify: `appcast.xml` only after a verified release package exists.

**Interfaces:**
- `scripts/package-dmg.sh development` creates a local-only DMG without appcast mutation.
- `scripts/package-dmg.sh release` requires signing/notary/Sparkle credentials and calls `scripts/verify-release.sh`.

- [ ] **Step 1: Add shell behavior checks and observe current failure**

In `verify-release.sh`, accept an app/DMG path and expected version/build. Assert bundle metadata, arm64-only executable, Developer ID authority and TeamIdentifier, runtime flag, secure timestamp, strict signature, stapled ticket, Gatekeeper acceptance, Sparkle signature, and declared file length. Running it on the 0.0.6 ad-hoc artifact must fail at Developer ID identity.

- [ ] **Step 2: Separate development and release modes**

Development mode passes ad-hoc settings, prints `LOCAL DEVELOPMENT ARTIFACT — DO NOT PUBLISH`, skips notary/appcast, and exits after mount/version/launch validation. Release mode validates the three `LUMEN_*` signing variables before building, enables Hardened Runtime, uses secure timestamps, submits with `xcrun notarytool submit --keychain-profile "$LUMEN_NOTARY_PROFILE" --wait`, staples, verifies, then generates the appcast.

- [ ] **Step 3: Advance the version and release notes**

Set all target version/build values to `0.0.7`/`7`, update structured website/README/release copy, and describe only verified features. Do not add a public release asset or appcast entry until release mode passes.

- [ ] **Step 4: Verify development packaging and commit**

Run syntax checks, tests, Release build, `scripts/package-dmg.sh development`, mount the DMG, and inspect version/architecture/adhoc status. Commit:

```bash
git add scripts Lumen.xcodeproj/project.pbxproj Info.plist README.md website docs/releases/v0.0.7.md
git commit -m "build: prepare trusted Lumen 0.0.7 release"
```

### Task 8: Final Verification, Integration, and Publication

**Files:**
- Modify after successful release packaging: `appcast.xml`
- Modify after successful release packaging: `docs/releases/v0.0.7.md` checksum if recorded there.

**Interfaces:**
- Produces: a commit on `main`, GitHub tag/release `v0.0.7`, latest appcast assets, and deployed GitHub Pages site only when every required gate is observed.

- [ ] **Step 1: Run fresh source verification**

Run full tests, Release build, analyze, website validation, shell syntax, plist lint, `git diff --check`, secret-pattern review, and verify the working tree contains only intended files.

- [ ] **Step 2: Self-review the complete diff**

Compare every design requirement to a commit and test. Inspect persistence migrations, retry idempotency, delete partial-failure behavior, diagnostics redaction, workflow permissions, and package fail-closed branches. Fix every Critical/Important finding with a new failing test where behavior changes.

- [ ] **Step 3: Merge and push the verified source**

Fast-forward or merge `agent/lumen-v007` into `main`, rerun the full suite on `main`, push, and verify GitHub Actions. Enable Dependabot security updates through GitHub API if repository permissions allow it.

- [ ] **Step 4: Run the real release path only when credentials exist**

If `security find-identity -v -p codesigning` lists a Developer ID Application identity and the notary profile is available, run `scripts/package-dmg.sh release`, then `scripts/verify-release.sh` against the final DMG. Update appcast, commit/push it, create tag `v0.0.7`, create the GitHub release with DMG/appcast/release notes, and verify downloads/checksums/Pages/update feed.

If the identity or notary profile is absent, do not publish an unsigned `v0.0.7` binary or latest appcast. Push the completed source and website, leave the tag/release absent, and report the exact one-time external credential step.

- [ ] **Step 5: Record final evidence**

Report test counts, build/analyze exits, CI run URLs, commit SHA, website URL, release URL/checksum when published, signing authority/team/runtime/notary/Gatekeeper results, and any UI-only audit that could not run because the Mac remained locked.

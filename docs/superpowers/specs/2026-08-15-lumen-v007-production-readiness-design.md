# Lumen 0.0.7 Production Readiness Design

## Objective

Ship Lumen 0.0.7 as a production-readiness release. The release makes private access the default, recovers local configuration safely, survives interrupted transfers without losing their history or exact destination, makes OSS-versioned deletes undoable, adds an in-app help surface, and establishes repeatable CI and notarized-release gates.

The release version is `0.0.7`, the bundle build number is `7`, and the public artifact name is `Lumen-0.0.7.dmg`. Lumen continues to target Apple Silicon and macOS 15 or later. Sparkle remains pinned to 2.9.2.

## Scope and Priorities

This release addresses the qualification gaps that can lose user data or undermine trust before adding broad storage-management features. It includes:

- private-by-default account setup and explicit confirmation for public permissions;
- recoverable account configuration with a last-known-good backup and visible recovery state;
- automatic retry for transient OSS failures with bounded exponential backoff;
- durable transfer history and retry descriptors, restored after relaunch as retryable interrupted jobs;
- version-aware delete receipts and one-level undo when OSS created delete markers;
- a real Help window, redacted diagnostics, privacy policy, security policy, contribution guide, and issue templates;
- application CI, dependency review, Dependabot configuration, website validation, and release-script checks;
- a production release path that refuses to publish without Developer ID signing, Hardened Runtime, timestamping, notarization, stapling, and Gatekeeper acceptance;
- focused accessibility improvements for labels, keyboard paths, focus visibility, Reduce Motion, and large text.

Global recursive search, drag-out download promises, cross-Bucket copy, a full trash browser, and byte-range/multipart checkpoint resume remain separate product projects. They involve navigation, authorization, and long-lived upload-session designs that should not be coupled to this safety release. Lumen 0.0.7 instead lays the durable queue and version-aware delete foundations those features require.

## Safety Defaults

### Account permissions

New accounts use `.private`. The common picker shows `继承 Bucket`, `私有`, and `公共读`. `公共读写` lives in the expanded advanced section and carries a destructive warning.

Changing from a non-public ACL to `公共读` or `公共读写` requires a second confirmation before the account can be saved. The confirmation names the exact access consequence. Cancelling restores the previous safe selection and sends no OSS request. Editing an existing public account remains possible and does not silently rewrite its setting.

### Configuration recovery

`AccountStore` becomes an injectable file-backed store with primary and backup URLs. A successful save validates its encoded data before replacing files. When a valid primary exists, it is copied to `accounts.backup.json` before the next primary write.

Loading produces a typed result:

```swift
struct AccountLoadResult: Sendable {
    var accounts: [OSSAccount]
    var recovery: AccountRecovery?
}
```

If the primary is corrupt and the backup is valid, Lumen loads the backup, preserves the corrupt file with a timestamped `.corrupt-...` suffix, restores a valid primary, and tells the user that the last-known-good account list was recovered. If neither file can be decoded, Lumen does not overwrite either file and opens with no accounts plus a persistent, actionable recovery message. Keychain secrets are never copied into these JSON files.

## Reliable Requests and Transfers

### Retry policy

Create a pure `OSSRetryPolicy` that retries connection loss, timeout, network-unavailable errors, HTTP 408/429, and HTTP 5xx. Authentication, permission, validation, conflict, cancellation, and other 4xx failures are not retried.

The default policy allows four total attempts with delays of 0.5, 1, and 2 seconds, capped at 4 seconds. A small bounded jitter prevents synchronized retries. Tests inject the sleeper and jitter source so they remain deterministic. Each attempt rebuilds and re-signs the request to avoid stale OSS timestamps.

### Durable transfer journal

`TransferJob` becomes Codable. A `TransferJournal` atomically stores sanitized jobs and durable retry records in Application Support. Retry records contain account ID, Bucket name, exact object key, transfer kind, source/destination bookmark data, and transfer options; they never contain an AccessKey secret, STS token, signed URL, or temporary transformed image.

The journal is updated on enqueue and every terminal state, with throttled progress writes. On launch:

- completed, failed, and cancelled history is restored;
- queued or running jobs from the previous process become failed with the message `上次退出时传输中断，可重试`;
- jobs with resolvable security-scoped bookmarks expose Retry and use the exact original key/destination;
- stale bookmarks keep the history but disable Retry with a specific explanation;
- clearing finished jobs removes their journal entries.

This is process-level recovery, not byte-level resume. A retry restarts an OSS request or multipart upload safely from the beginning and retains existing CRC64 and no-overwrite guarantees.

## Version-Aware Delete Recovery

`OSSClient.deleteObject` returns an `OSSDeleteReceipt` containing the object key, `x-oss-delete-marker`, and `x-oss-version-id`. A receipt is recoverable only when OSS reports that the deletion created a delete marker and supplies its version ID.

After deleting one or more objects:

- if every deletion returned a recoverable marker, Lumen stores one scoped `CloudDeleteUndoOperation`, presents `已移到 OSS 删除标记 · 撤销`, and exposes `⌘Z`;
- undo removes the exact delete-marker versions using `DELETE ?versionId=...`, which makes the prior versions current again;
- if any deletion is permanent because versioning is not active, the dialog states that fact before execution and Lumen does not claim the batch is undoable;
- a failed multi-object delete records only receipts actually returned, reports partial completion precisely, and never claims the untouched items were deleted;
- delete undo is scoped to the exact account and Bucket and is cleared only after every marker removal succeeds.

The existing rename/move undo and delete undo share one semantic undo slot: the most recent successfully completed reversible cloud operation wins. The UI never offers redo.

## Help, Privacy, and Diagnostics

The Help menu opens a native `HelpView` instead of sending users directly to the repository. It contains:

- first connection guidance and least-privilege RAM advice;
- transfer, conflict, delete-recovery, and automatic-update explanations;
- keyboard shortcuts;
- links to the website, privacy page, Security Policy, release notes, and issue form;
- a `复制诊断信息` action.

`DiagnosticsReport` contains only app version/build, macOS version, architecture, update feed host, counts of configured accounts and active/failed transfers, and non-secret feature settings. It excludes account names, Bucket names, regions tied to an account, object keys, local paths, AccessKey IDs, secrets, tokens, URLs, and request IDs.

The website adds `privacy.html` and `support.html` using the existing visual language. The README links to both. `SECURITY.md` defines private vulnerability reporting through GitHub Security Advisories and supported versions. `CONTRIBUTING.md` documents the local test/release boundaries. Issue forms request reproducible, already-redacted information.

## Accessibility and Interaction

The app keeps native macOS controls and restrained motion. Work in this release focuses on observable platform behavior:

- every icon-only button has an accessibility label and Help text;
- permission warnings and recovery banners expose a single meaningful announcement;
- actionable banners keep separate action and dismiss controls;
- Help supports full keyboard navigation and text selection;
- focus rings remain visible; color is never the only status channel;
- Reduce Motion replaces movement with short opacity changes;
- transfer status includes text in addition to progress color;
- key screens remain usable with the system's larger accessibility text sizes without truncating primary actions.

Automated checks cover labels and state derivation where feasible. A manual VoiceOver audit remains a release checklist item and must be reported as blocked rather than passed when the Mac UI cannot be unlocked.

## CI and Supply-Chain Gates

Add an application workflow that runs on pull requests, pushes to `main`, and manual dispatch. It:

1. validates the resolved Swift package graph without updating it;
2. runs the full macOS test suite with real OSS smoke tests disabled;
3. builds Release and runs static analysis;
4. validates the website and release metadata;
5. verifies shell scripts with `bash -n` and checks plist/privacy files with `plutil`.

GitHub dependency review runs on pull requests. Dependabot checks GitHub Actions weekly and Swift Package Manager monthly. Secret scanning and push protection remain enabled. CI uses no OSS credentials and never has access to the Sparkle private key.

## Release Trust Chain

The package script has two explicit modes:

- `development`: produces a local ad-hoc DMG for testing, labels it as non-publishable, and never updates `appcast.xml`;
- `release`: requires `LUMEN_DEVELOPER_ID_APPLICATION`, `LUMEN_DEVELOPMENT_TEAM`, and `LUMEN_NOTARY_PROFILE`; builds Release with Hardened Runtime, signs nested code and the app with a secure timestamp, verifies strict signatures, creates the DMG, submits it with `notarytool --wait`, staples the ticket, verifies stapling, and requires `spctl --assess --type open --context context:primary-signature` to accept it before appcast generation.

The release mode fails closed if the identity, notary profile, Sparkle signing key, expected version, architecture, or any verification is missing. It never falls back to ad-hoc signing. GitHub publication happens only after this script succeeds.

The current machine has no valid code-signing identities, so 0.0.7 code and website work can be completed and pushed, but a public 0.0.7 binary release cannot honestly be completed until a Developer ID Application certificate and notarization credentials are installed.

## Website Direction

The site remains a quiet, platform-native product page rather than adopting a new campaign style.

- Palette: Lumen Blue `#087CFA`, Deep Blue `#006BDC`, Window Canvas `#F4F6F9`, Paper `#FFFFFF`, Ink `#11141A`, Slate `#616874`.
- Type: the macOS system family for display and body, with SF Mono/Menlo only for paths, versions, and machine-readable labels.
- Layout: policy/support pages reuse the translucent header and a narrow readable document column; no cards are added where plain sections are clearer.
- Signature: OSS paths appear as restrained breadcrumb annotations, connecting support text to the product's file-browser purpose.
- Motion: only existing hover/focus transitions, with the current reduced-motion override.

This deliberately avoids generic gradient heroes, decorative numbered cards, stock illustrations, and excessive glass effects. The new pages serve comprehension and trust.

## Testing and Release Acceptance

0.0.7 is ready for source integration when all new focused tests and the complete suite pass, Release builds without warnings introduced by this change, CI configuration validates, website checks pass, and the diff has no secrets or unrelated files.

The binary is ready for public publication only when all of the following are freshly verified against the actual DMG:

- bundle version `0.0.7` and build `7`;
- Apple Silicon executable;
- Developer ID team identifier present;
- Hardened Runtime and secure timestamp present;
- `codesign --verify --deep --strict` succeeds;
- `stapler validate` succeeds;
- Gatekeeper accepts the mounted app;
- Sparkle Ed25519 signature and declared file length match the DMG;
- update from 0.0.6 to 0.0.7 installs and relaunches when an unlocked UI is available;
- GitHub release, `appcast.xml`, README, and website all point to the same artifact and checksum.

If any external credential or unlocked-UI gate is unavailable, the release remains unpublished and the exact blocker is recorded. No README or website copy may claim a trust property that was not observed.

# Lumen 0.0.9 Product Integration and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Repository instructions prohibit subagent creation without separate user approval. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate native tabs and commands, complete accessibility/design review, update public materials to 0.0.9, verify the product, and publish/install the release.

**Architecture:** Keep scene/window state in SwiftUI and shared service state in `AppServices`. Documentation and website reuse the existing visual direction and fixed screenshot dimensions. Existing release scripts remain the single artifact-generation path; publication happens through a reviewed PR and GitHub CLI after all local gates pass.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest/Swift Testing, HTML/CSS, shell, Xcode 26.2, GitHub Actions/Pages, Sparkle.

## Global Constraints

- Marketing version is `0.0.9`; build number is `9`.
- macOS 15 and arm64 support remain unchanged.
- Browser and account screenshots remain exactly 2480 × 1600 pixels and use synthetic data.
- Website screenshot display dimensions remain unchanged.
- No prose about distribution-signing status is added.
- Release publication waits for full local and GitHub verification.

---

### Task 1: Native Window Tabs, Commands, and Link Lifetime

**Files:**
- Modify: `Lumen/LumenApp.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/App/AppSettings.swift`
- Modify: `Lumen/Views/SettingsView.swift`
- Modify: `LumenTests/AppModelTests.swift`

**Interfaces:**
- `Command-N` opens a new main window; `Shift-Command-A` adds an account.
- `Command-Option-L` opens Transfers; `Command-I` remains Information.
- All link copy paths consume `settings.signedLinkLifetime.seconds`.

- [ ] **Step 1: Write failing command-state and link-expiry tests**

Assert a new window inherits current account/Bucket/prefix but not selection. Assert signed URL query expiration uses literal values 3600, 86400, and 604800 based on the setting.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-release -only-testing:LumenTests/AppModelTests -only-testing:LumenTests/SafetyAndVersionTests test
```

Expected: link copy still uses the fixed one-hour value and command routing is absent.

- [ ] **Step 3: Enable native tabs and commands**

Remove the `allowsAutomaticWindowTabbing = false` override. Restore standard new-window behavior through `openWindow(id:"main")`, move account shortcut, and add Transfer/Version/Properties commands with correct availability. Preserve standard Window menu tab actions.

- [ ] **Step 4: Route signed-link lifetime everywhere**

Pass the setting into plain, Markdown, HTML, folder URL, upload result, and inspector copy paths. Keep public CDN URLs un-signed.

- [ ] **Step 5: Run focused tests and build**

Run Step 2 and a normal build. Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/LumenApp.swift Lumen/App/AppModel.swift Lumen/App/AppSettings.swift Lumen/Views/SettingsView.swift LumenTests/AppModelTests.swift
git commit -m "feat: complete native window workflows"
```

### Task 2: Apple Interaction, Accessibility, and Help Review

**Files:**
- Modify: `Lumen/Views/BucketSearchView.swift`
- Modify: `Lumen/Views/TransferWindow.swift`
- Modify: `Lumen/Views/VersionHistoryView.swift`
- Modify: `Lumen/Views/ObjectPropertiesView.swift`
- Modify: `Lumen/Views/CrossBucketPreflightView.swift`
- Modify: `Lumen/Views/HelpView.swift`
- Modify: `Lumen/LumenApp.swift`

**Interfaces:**
- Every icon-only action has accessibility label and help.
- Escape, Return, Space, Command-I, Command-N, Command-Option-L, and tab traversal follow native expectations.

- [ ] **Step 1: Audit every new surface against the design checklist**

Verify status/completion/warning/error feedback, source-anchored sheets/popovers, semantic colors, minimum desktop hit regions, no stacked translucent cards, direct labels, keyboard order, light/dark mode, VoiceOver names, and no color-only status. Record and fix each concrete issue in the same pass.

- [ ] **Step 2: Apply reduced-motion behavior**

Any custom search/transfer transition uses `reduceMotion ? .opacity :` a short critically damped move. No looping, bounce, decorative background motion, or input lockout remains.

- [ ] **Step 3: Update Help**

Document search scope, transfer pause/resume, drag to Finder, version recovery, properties, cross-Bucket method warnings, tabs, and shortcuts in task language. Keep limitations precise.

- [ ] **Step 4: Build and run the complete test suite**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-release test
```

Expected: all automated tests pass except the credential-gated real OSS smoke test, which is skipped.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Views Lumen/LumenApp.swift
git commit -m "design: polish Lumen 0.0.9 workflows"
```

### Task 3: Version, Synthetic Screenshots, README, Website, and Notes

**Files:**
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Modify: `scripts/package-dmg.sh`
- Modify: `scripts/validate-website.sh`
- Modify: `README.md`
- Modify: `website/index.html`
- Modify: `website/support.html`
- Modify: `website/privacy.html`
- Modify: `website/styles.css` only when new copy needs responsive adjustment
- Modify: `Lumen/App/ScreenshotDemo.swift`
- Modify: `LumenTests/ScreenshotDemoTests.swift`
- Modify: `docs/browser.png`
- Modify: `docs/account.png` only if account UI changed materially
- Modify: `website/assets/browser.png`
- Modify: `website/assets/account.png` only if regenerated
- Create: `docs/releases/v0.0.9.md`

**Interfaces:**
- Produces built version `0.0.9 (9)` and package name `Lumen-0.0.9.dmg`.

- [ ] **Step 1: Change version expectations in tests first and verify RED**

Update version assertions and website validator expectation to 0.0.9 (9), then run `SafetyAndVersionTests`, `UpdateServiceTests`, and `ScreenshotDemoTests`. Expected: project version and download links still report 0.0.8.

- [ ] **Step 2: Update project/package versions and release notes**

Set every app/test marketing version to 0.0.9, build to 9, release derived path to v009, temp DMG prefix to v009, and artifact name to `Lumen-0.0.9.dmg`. Write concise Chinese release notes grouped as Find, Transfer, Recover, Organize, and Mac integration.

- [ ] **Step 3: Rewrite README around the complete workflow**

Lead with one plain sentence and the real product screenshot. Explain search, durable transfers, Finder export, versions, properties, cross-Bucket behavior, settings, privacy, installation, update, scope/limits, and development. Keep links current and avoid a mechanical feature dump.

- [ ] **Step 4: Update the website without changing its identity**

Keep the current light, restrained Lumen visual language and screenshot framing. Update version/download/schema metadata and replace capability copy with short task-led sections. Do not add gradients, floating card stacks, fake testimonials, counters, or decorative animation.

- [ ] **Step 5: Regenerate synthetic screenshots**

Build Debug and launch screenshot modes. Capture only synthetic `Lumen Demo` data. Export browser and account images at exactly 2480 × 1600; verify dimensions with `sips -g pixelWidth -g pixelHeight`, inspect visually, and copy the exact same optimized assets to docs and website. The browser screenshot shows Bucket results and compact transfer summary without selected secrets.

- [ ] **Step 6: Validate documentation and metadata**

```bash
scripts/validate-website.sh
bash -n scripts/*.sh
zsh -n scripts/*.sh
plutil -lint Info.plist Lumen/PrivacyInfo.xcprivacy
xmllint --noout appcast.xml
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 7: Commit**

```bash
git add Lumen.xcodeproj/project.pbxproj scripts README.md website Lumen/App/ScreenshotDemo.swift LumenTests/ScreenshotDemoTests.swift docs
git commit -m "docs: prepare Lumen 0.0.9 release"
```

### Task 4: Full Local Verification

**Files:**
- No source changes unless a failing gate is reproduced with a regression test first.

**Interfaces:**
- Produces fresh evidence for tests, analysis, Release build, website, metadata, and development package.

- [ ] **Step 1: Run the complete test suite**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-final -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates test
```

- [ ] **Step 2: Run static analysis and Release build**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-final analyze
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-final -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build
```

- [ ] **Step 3: Run documentation/metadata gates and verify screenshots**

Run Task 3 Step 6, `sips` dimension checks, `git status -sb`, and `git diff --stat origin/main...HEAD`. Confirm no production fixture, secret, local path, or ignored build artifact is staged.

- [ ] **Step 4: Build and inspect the development DMG**

```bash
scripts/package-dmg.sh development
hdiutil verify dist/Lumen-0.0.9-development.dmg
```

Mount read-only, verify `Lumen.app` reports 0.0.9 (9), launch it, and inspect main/search/transfer/version/properties/settings surfaces when the desktop session is available.

- [ ] **Step 5: Fix only reproduced failures through RED-GREEN tests, then rerun the complete failed gate and all prior gates affected**

- [ ] **Step 6: Commit any verified fixes and ensure a clean worktree**

### Task 5: Pull Request, Merge, Release, Update Feed, and Local Install

**Files:**
- Modify: `appcast.xml` only through `scripts/package-dmg.sh release` after artifact verification.
- Generate ignored: `dist/Lumen-0.0.9.dmg`, `dist/appcast.xml`.

**Interfaces:**
- Produces GitHub Release `v0.0.9`, updated Pages site, live appcast entry, and `/Applications/Lumen.app` version 0.0.9 (9).

- [ ] **Step 1: Push and open the pull request**

Push `agent/lumen-009-implementation`, open a PR to `main`, and include user impact, architecture, safety behavior, and exact verification commands/results. Mark ready for review because the user requested publication.

- [ ] **Step 2: Wait for and inspect all PR checks**

Use `gh pr checks --watch`. If a check fails, inspect logs, reproduce locally, add a failing regression test where behavior changed, fix, rerun, commit, and push.

- [ ] **Step 3: Merge and verify main**

Merge only after required checks pass. Pull the new main in the release checkout and verify the merge commit plus main CI/Pages workflows.

- [ ] **Step 4: Generate the public release artifact**

Run `scripts/package-dmg.sh release` with the configured release environment. The script must finish its own artifact and appcast verification before tracked `appcast.xml` changes. Commit and push the verified appcast update.

- [ ] **Step 5: Create GitHub Release and upload exact assets**

Create `v0.0.9` from merged main, use `docs/releases/v0.0.9.md`, and upload `dist/Lumen-0.0.9.dmg` plus `dist/appcast.xml`. Do not overwrite an existing release or asset silently.

- [ ] **Step 6: Verify online publication independently**

Download the Release DMG/appcast to a fresh temporary directory, compare SHA-256 and byte length with local outputs, verify appcast version/build/download URL, wait for Pages success, and open the public website and download link.

- [ ] **Step 7: Install the published DMG locally**

Move the existing `/Applications/Lumen.app` to a versioned recoverable backup in Trash, install the app from the freshly downloaded public DMG, verify 0.0.9 (9), launch it, and verify the running bundle path is `/Applications/Lumen.app`.

- [ ] **Step 8: Report publication evidence**

Report Release URL, PR URL, merge/appcast commits, test count and skip, CI/Pages state, public artifact digest, installed version, and recoverable local backup location.


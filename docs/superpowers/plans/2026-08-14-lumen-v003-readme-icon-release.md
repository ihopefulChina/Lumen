# Lumen 0.0.3 README, Icon, and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lumen 0.0.3 with a product-quality README, a restrained native macOS icon, and a newly verified public GitHub release.

**Architecture:** README content remains a single GitHub-facing document. A generated 1024 px icon master is downsampled into the existing macOS AppIcon asset catalog with v6 filenames. The existing release script remains the single packaging path; publication replaces the unpublished tag with an exact lease and uses GitHub CLI.

**Tech Stack:** Markdown, Xcode asset catalogs, PNG, `sips`, Swift 6/SwiftUI, `xcodebuild`, `codesign`, `hdiutil`, Git, GitHub CLI.

## Global Constraints

- Product version stays `0.0.3` with build number `3`.
- Platform stays Apple Silicon and macOS 15 or later.
- Public DMG packaging must preserve the established application identity and data path.
- Do not add third-party runtime or build dependencies.
- Do not publish until the rebuilt public asset hash is verified.
- Do not use subagents; execute inline in the current session.

---

### Task 1: Product README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `docs/browser.png`, `docs/account.png`, release URL, v6 icon asset path.
- Produces: the public product and installation documentation for release 0.0.3.

- [ ] **Step 1: Replace the header and product promise**

Use the v6 256 px icon, one positioning sentence, one primary screenshot, and immediate Download / macOS 15+ / Apple Silicon facts.

- [ ] **Step 2: Recompose user guidance**

Write three value propositions, a three-step quick start, grouped capabilities, and a compact shortcut table. Remove defensive comparisons and long setting enumeration.

- [ ] **Step 3: State security and limits accurately**

Document local credential storage, RAM-user recommendation, ACL behavior, no-overwrite behavior, pagination protection, and no recycle bin.

- [ ] **Step 4: Review rendered Markdown and commit**

Run:

```bash
rg -n "0\.0\.2|右键 App|反选|套壳" README.md
git diff --check
git add README.md
git commit -m "docs: rewrite README as a Mac product page"
```

Expected: no stale release copy, no whitespace errors, and one focused README commit.

### Task 2: Native macOS App Icon

**Files:**
- Create: `Lumen/Assets.xcassets/AppIcon.appiconset/Icon-v6-*.png`
- Modify: `Lumen/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Remove: `Lumen/Assets.xcassets/AppIcon.appiconset/Icon-v5-*.png`

**Interfaces:**
- Consumes: one inspected 1024×1024 generated master.
- Produces: ten PNGs matching the macOS 16, 32, 128, 256, 512, and Retina slots.

- [ ] **Step 1: Generate the 1024 px master**

Use the built-in image generator with this specification:

```text
Use case: logo-brand
Asset type: native macOS application icon master
Primary request: create a restrained luminous folder-tray icon for a native OSS file browser
Style/medium: crisp vector-like geometric illustration with subtle physical depth
Composition: transparent 1024×1024 canvas; centered macOS rounded-square tile; one folder silhouette with a narrow vertical light seam
Color palette: deep indigo and cool blue tile, off-white folder, small cyan accent
Constraints: legible at 16 px; balanced macOS icon proportions; no text or letters
Avoid: cloud, checkmark, upload arrow, red, Alibaba logo, glass, jelly highlights, excessive glow, bevels, sparkles, particles, photorealism, watermark
```

- [ ] **Step 2: Inspect and resize the selected master**

Inspect the master at full size and at 64 px. Use `sips --resampleHeightWidth` to create exact slot sizes and retain alpha.

- [ ] **Step 3: Update the asset manifest and remove v5 files**

Replace every `Icon-v5-` filename with the corresponding `Icon-v6-` filename. Remove only the ten tracked v5 PNGs after the v6 set exists.

- [ ] **Step 4: Verify the asset catalog and commit**

Run:

```bash
plutil -lint Lumen/Assets.xcassets/AppIcon.appiconset/Contents.json
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' build
git diff --check
git add Lumen/Assets.xcassets/AppIcon.appiconset
git commit -m "design: replace the Lumen app icon"
```

Expected: asset compilation succeeds and every referenced PNG exists at its declared size.

### Task 3: Rebuild and Verify 0.0.3

**Files:**
- Modify: `docs/releases/v0.0.3.md`
- Modify: `docs/superpowers/checklists/2026-08-14-lumen-v0.0.3-release.md`
- Generate: `dist/Lumen-0.0.3.dmg`

**Interfaces:**
- Consumes: final README and v6 asset catalog.
- Produces: one verified DMG and final release notes.

- [ ] **Step 1: Run fresh automated gates**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Debug -destination 'platform=macOS,arch=arm64' clean test
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -destination 'platform=macOS,arch=arm64' analyze CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

- [ ] **Step 2: Rebuild the DMG from the final commit**

Move the earlier generated artifact aside, run `scripts/package-dmg.sh`, and record its new SHA-256 in the release notes. Confirm its mounted app displays the v6 icon and launches.

- [ ] **Step 3: Record evidence and commit**

Update the checklist with the fresh test, build, asset, and package results. Commit only documentation evidence; the ignored DMG remains in `dist/`.

### Task 4: Replace the Tag and Publish

**Files:**
- Upload: `dist/Lumen-0.0.3.dmg`

**Interfaces:**
- Consumes: final main commit, expected old annotated-tag object `a2c83b95de91544a690e2efc77f58521eff13006`, release notes, verified DMG.
- Produces: public non-draft, non-prerelease GitHub Release `v0.0.3` with one DMG asset.

- [ ] **Step 1: Push main and replace only the expected old tag**

```bash
git push origin main
git tag -fa v0.0.3 -m "Lumen 0.0.3"
git push --force-with-lease=refs/tags/v0.0.3:a2c83b95de91544a690e2efc77f58521eff13006 origin refs/tags/v0.0.3
```

- [ ] **Step 2: Publish through GitHub CLI**

```bash
gh release create v0.0.3 dist/Lumen-0.0.3.dmg \
  --repo ihopefulChina/Lumen \
  --title "Lumen 0.0.3" \
  --notes-file docs/releases/v0.0.3.md \
  --latest
```

- [ ] **Step 3: Download and verify the public artifact**

Download the single release asset to a fresh temporary directory, compare SHA-256, and inspect `gh release view v0.0.3 --json isDraft,isPrerelease,isLatest,url,assets`.

- [ ] **Step 4: Final repository audit**

Confirm `main` is clean and matches `origin/main`, the tag peels to `main`, and the public release URL responds successfully.

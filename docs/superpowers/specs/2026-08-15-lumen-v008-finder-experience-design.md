# Lumen 0.0.8 Finder Experience Design

## Product Intent

Lumen is a focused macOS file browser for Alibaba Cloud OSS. Version 0.0.8 should feel calmer and more familiar to people who already understand Finder: the file list owns the window, secondary information appears only when requested, account setup reads like a native Mac task, and Settings exposes useful defaults without becoming an administration console.

The visual goal is confidence rather than decoration. Lumen continues to use SF typography, SF Symbols, semantic system colors, native controls, keyboard navigation, reduced-motion behavior, and light/dark mode supplied by macOS.

## Chosen Direction

Three directions were considered:

1. **Finder-native, contextual information (chosen).** Remove the persistent right inspector column, present information in a compact sheet on demand, simplify account setup, and reorganize Settings around user tasks.
2. **Cosmetic restyle.** Keep the right inspector and current form hierarchy but change spacing and backgrounds. This is lower risk but does not address the structural reason the window feels unlike Finder.
3. **Full setup assistant and customizable panes.** Add a multi-step account wizard and user-configurable panels. This adds ceremony and state for a connection form that should remain a single short task.

The first direction is the smallest change that fixes the product-level issue rather than decorating it.

## Native Design Language

- **Surfaces:** `windowBackgroundColor`, `controlBackgroundColor`, separators, and system materials only. No decorative gradients, floating card stacks, or web-style glass panels.
- **Color:** system accent for selection and primary actions, semantic red for destructive actions, orange only for public-access warnings, and system secondary/tertiary text for hierarchy.
- **Typography:** SF system text styles. Titles use `.title2` or `.title3` with semibold weight; form labels use native Form metrics; object paths and identifiers use monospaced caption styles.
- **Spacing:** 8 points between related controls, 12–16 points inside sections, and 20–24 points between major regions. Alignment and proximity carry hierarchy instead of borders around every group.
- **Icons:** SF Symbols with hierarchical rendering. Controls retain at least a 28-point desktop hit region and descriptive accessibility labels/help.
- **Motion:** native sheet presentation and short, critically damped state changes. Reduced Motion replaces movement with opacity changes; no decorative entrance animation is added.

The distinctive gesture of 0.0.8 is restraint: the browser becomes full width, while information materializes from the toolbar only when the user asks for it.

## Main Window and Information

The main workspace removes SwiftUI's persistent `.inspector` column. The existing toolbar information button remains, but it presents a compact native sheet instead of consuming the right edge of the file browser. The Browse menu gains “显示信息” with `Command-I`.

The information sheet supports the same four contexts as the old inspector:

- multiple selection: counts, aggregate known size, download, and delete;
- one object: preview or text excerpt, name/path, object metadata, link actions, Quick Look, download, and delete;
- current folder or Bucket: path, visible folder/object counts, region, and folder download;
- unavailable context: a native `ContentUnavailableView` with a direct explanation.

Content uses plain sections separated by native dividers rather than cards. Primary file actions appear together; destructive deletion is spatially separated. The sheet is 420 points wide, scrolls vertically, closes with Escape or a “完成” button, and updates if the selection changes while open.

The main file browser never opens this sheet automatically. Closing it restores the complete browser width and focus.

## Account Setup

The account editor remains one sheet because the common path fits in one view. It no longer embeds an iOS-like `NavigationStack` hierarchy. Its structure is:

1. a restrained header with the system cloud/key icon, “添加账号” or “编辑账号,” and one sentence explaining local Keychain storage;
2. a native grouped Form containing Connection, Storage, and Upload sections;
3. an “高级选项” DisclosureGroup for STS Token, custom Endpoint, CDN domain, and public-read-write access;
4. an inline connection error next to the form outcome;
5. a bottom bar with Cancel and the single primary Add/Save action.

Secret reveal remains an icon button with a help label. The primary button reports “正在连接…” while disabled during the network probe. Public read or public read/write still requires explicit confirmation; inherited or private permission does not.

### Default Permission

`AccountDraft.fresh()` changes from `.private` to `.default`, whose user-facing title is “继承存储空间.” This applies only to newly added accounts. Existing saved accounts retain their exact value.

Uploads with `.default` omit an object ACL override and therefore follow the Bucket policy. When an account uses `.default` and has no CDN domain, copied links use a temporary signed URL as a safe compatibility choice; public Buckets still accept that URL, while private Buckets remain usable.

The screenshot fixture and regression tests use the inherited default so documentation matches the real first-run behavior.

## Settings

Settings uses three standard macOS tabs sized for readable Form content:

### General

- preferred browser view: Grid or List;
- show only supported media/text items;
- automatic update checks and manual “检查更新…”;
- current version and support links.

The preferred view is persisted. New windows use it. Changing it in Settings also updates existing Lumen windows, and changing the main toolbar view updates the stored preference.

### Transfers

- concurrent uploads;
- HEIC-to-JPEG conversion;
- completion sound;
- menu-bar transfer status;
- completed/failed history count and “清除已完成记录,” disabled while there is nothing removable.

### Accounts

- a native account row with cloud icon, display name, region, and upload-permission summary;
- Edit and Check Connection actions;
- connection feedback that reports the Bucket count or a concise recovery error;
- an “添加账号…” action in the standard bottom position.

Account checks read credentials from Keychain and list Buckets without changing the active account, browser location, or saved settings.

## Data and Compatibility

- No account data migration is introduced. Codable account schema remains compatible with 0.0.7.
- `AppSettings` gains a persisted `preferredViewMode`; absence defaults to Grid to preserve current behavior.
- The new connection-check result is view-local and is never persisted.
- Transfer history clearing uses the existing `TransferEngine.clearFinished()` path and retains active jobs.
- No new runtime dependency is added.

## Accessibility and Failure Handling

- Every icon-only control has a label and help text.
- Form labels remain visible; placeholders are examples, not labels.
- Connection errors remain selectable/readable, identify the failed action, and leave all entered values intact.
- Loading buttons are disabled and show progress.
- Keyboard order follows visual order; `Command-I`, Escape, Return, and standard tab traversal work.
- Light/dark mode uses semantic system colors; color is never the only status indicator.
- Reduced Motion is respected by existing motion helpers and native sheet behavior.

## Documentation and Release

- Marketing version becomes `0.0.8`; build becomes `8` everywhere.
- README, website copy, release notes, automatic-update feed, and download links describe 0.0.8.
- Product screenshots use synthetic data. The browser screenshot shows the full-width browser without a right inspector, and the account screenshot shows inherited Bucket permission.
- The website maintains the existing image display dimensions so the repository and release package do not grow unnecessarily.
- The public release contains `Lumen-0.0.8.dmg` and `appcast.xml`; the appcast DMG length and Sparkle EdDSA signature must verify before publication.
- The installed local `/Applications/Lumen.app` is updated from the published DMG and verified as `0.0.8 (8)`.

## Verification

Completion requires:

- regression tests for inherited permission, signed-link fallback, preferred view persistence/application, connection checking, and transfer-history clearing behavior;
- the complete macOS test suite with no failures;
- arm64 Release build and static analysis;
- website, plist, XML, YAML, and shell validation;
- synthetic screenshot inspection when the desktop session permits capture;
- GitHub pull-request checks, main checks, Pages deployment, online asset digests, appcast contents, and local installed-version verification.

The real OSS smoke test remains opt-in because CI and screenshots must never receive production credentials.

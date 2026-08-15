# Lumen 0.0.9 Complete Finder Workflow Design

## Product Intent

Lumen 0.0.9 turns the existing single-window OSS browser into a dependable Finder companion. A person should be able to locate an object anywhere in a Bucket, move data between useful locations, drag cloud files back to Finder, pause a long transfer, recover after an interruption, and restore an earlier object version without leaving the app.

The release remains focused on object work. It does not become a replacement for the OSS administration console: Bucket creation, lifecycle rules, CORS, RAM policies, replication policies, and unfinished multipart administration stay out of the main product.

## Chosen Direction

Three directions were considered:

1. **Finder-first, integrated workflows (chosen).** Add Bucket search, durable transfers, Finder export, version recovery, cross-Bucket organization, object properties, native tabs, and smart locations around the existing browser model.
2. **Console breadth.** Add Bucket creation and configuration before improving file workflows. This increases permission risk and interface density while leaving the common search and transfer gaps unresolved.
3. **Synchronization first.** Build watched local folders and bidirectional synchronization. This requires mature checkpointing, conflict policies, deletion recovery, and background execution first; starting here would make data-loss behavior harder to reason about.

The first direction matches Lumen's promise and creates foundations a later opt-in synchronization feature could safely reuse.

## Delivery Decomposition

The release is intentionally implemented as four bounded, sequential subprojects rather than one unreviewable change:

1. **Search and locations:** paged scanning, Bucket search, result navigation, and contextual smart locations.
2. **Durable transfers and Finder export:** checkpoint formats, pause/resume, transfer window, policies/settings, and promised files.
3. **Cloud safety tools:** version recovery, cross-Bucket organization, metadata, and tags.
4. **Product integration and release:** native tabs/commands, help, accessibility review, screenshots, README, website, versioning, packaging, and publication.

Each subproject has its own implementation plan and test gate. Later plans consume explicit value types and services produced by earlier plans; the public version changes only after all four gates pass.

## Release Scope

Version 0.0.9 includes these connected capabilities:

- current-folder and current-Bucket search with useful filters and cancellable progress;
- a full transfer window with pause, resume, persistent upload/download checkpoints, speed and remaining-time feedback, queue priority, and batch conflict policies;
- dragging selected OSS objects or folders to Finder through an asynchronous promised file representation;
- object version history, deleted-object recovery, and safe restoration of an earlier version;
- same-account cross-Bucket copy or move, using server-side copy when the Buckets share a region and a visible local relay when they do not;
- editing standard HTTP metadata, user metadata, and object tags;
- native macOS window tabs and additional smart locations for recent objects, large objects, deleted objects, and failed transfers;
- settings for download location, conflict behavior, signed-link lifetime, upload/download concurrency, speed limiting, and completion notifications;
- README, website, screenshots, help, release notes, package version, update feed, and local installation updated to 0.0.9.

## Native Interaction Model

Lumen continues to use semantic system colors, SF typography, SF Symbols, native sheets, menus, tables, search fields, progress controls, light/dark mode, keyboard navigation, and reduced-motion behavior.

The common path stays visually quiet:

- search scope and filters appear adjacent to the active search rather than as permanent chrome;
- transfers leave the bottom tray and open in a dedicated window when detail or control is needed;
- version history and object properties open only for a selected object;
- sidebar smart locations use familiar Finder-like labels and do not mix with Bucket administration;
- destructive or billable cross-region work shows the method and estimated size before it starts;
- all long operations expose status, completion, warning, or recovery feedback and remain cancellable.

Native window tabbing is enabled. `Command-N` opens a new Lumen window; account creation moves to `Shift-Command-A`. New windows inherit the focused window's account, Bucket, and path without sharing selection or in-flight navigation state.

## Bucket Search and Smart Locations

### Search scopes

The toolbar search field supports two scopes:

- **当前文件夹:** the existing immediate in-memory filter;
- **当前 Bucket:** an asynchronous recursive search across the selected Bucket.

Bucket search matches a case- and width-insensitive substring of the full object key. The result list shows filename, containing path, size, modified time, and storage class. Double-click opens the containing folder and selects the object; Space downloads a temporary copy for Quick Look; context actions remain available.

Optional filters cover file kind, modified-date range, and minimum/maximum size. Filters never issue one HEAD request per result. Search works from `ListObjectsV2`, consumes pages incrementally, reports scanned and matched counts, accepts cancellation, detects repeated/missing continuation tokens, and marks capped results as incomplete instead of implying full coverage. A successful result set is cached in memory per account/Bucket/query/filter tuple and invalidated after mutations.

### Smart locations

The sidebar adds a `位置` section:

- **最近修改:** objects modified in the last seven days, newest first;
- **大文件:** objects at least 100 MB, largest first;
- **已删除:** delete markers from version-enabled Buckets;
- **失败的传输:** failed or interrupted jobs from the durable transfer journal.

Recent and large locations reuse the same cancellable paged scanner as Bucket search. Deleted objects use the version-listing API. Failed transfers open the transfer window with its failed filter selected. Smart locations are contextual to the selected account and Bucket and never pretend to be local folders.

## Durable Transfer Center

### Transfer state

`TransferJob` gains a paused state and enough persisted information to resume the exact target. A paused job is not counted as active, retains its checkpoint and security-scoped bookmark, and can be resumed or cancelled. On graceful application termination, running resumable jobs are converted to paused jobs before the process exits. On the next launch, valid paused jobs are restored as resumable; invalid bookmarks or changed source files remain visible with a specific recovery explanation.

### Upload checkpoints

Multipart uploads persist the OSS upload ID, object key, source size, source modification date, part size, and completed part numbers/ETags after every completed part. Resume validates the account, Bucket, key, source identity, and checkpoint before uploading only missing parts. Successful completion removes the checkpoint. Explicit cancellation aborts the remote multipart upload; pause and recoverable failure preserve it.

Small uploads restart from byte zero because OSS simple upload has no multipart checkpoint. The UI labels this accurately.

### Download checkpoints

Downloads write to a stable hidden partial file beside the chosen destination. Large and small objects are fetched in bounded byte ranges, appending a completed range before the journal advances. A pause or process exit loses at most the current range and resumes from the last persisted byte. Completion verifies the full local CRC64 when OSS exposes the object CRC, then atomically publishes the destination. The final destination is never overwritten silently.

### Controls and feedback

The dedicated transfer window supports:

- All, Active, Paused, Failed, and Completed filters;
- pause/resume/cancel per job and corresponding bulk actions;
- retry for recoverable failures;
- move-to-top for queued jobs;
- progress, current speed, transferred/total bytes, and stable remaining-time estimates;
- Reveal in Finder for completed downloads and Copy Link for uploads;
- concise error details and a copyable request ID when available.

The existing bottom tray becomes a compact summary with an `打开传输` action. It does not expand enough to cover browser content.

### Policies and settings

Upload conflict behavior is persisted as Ask, Skip, Replace, or Keep Both. Ask presents one batch decision and can apply it to the remaining items. Keep Both creates a Finder-style numbered destination name before enqueueing.

Upload and download concurrency are configured separately from 1 through 6. Optional speed limiting applies a shared per-direction ceiling of Unlimited, 5 MB/s, 20 MB/s, or 50 MB/s. Remaining-time feedback is hidden until enough samples exist. Completion notification is opt-in and requested only when the user enables it.

Default download location supports Ask Every Time or Downloads. A custom security-scoped folder is not added in this release because a stale persistent folder grant is less predictable than these two explicit choices.

## Finder Export

Dragging an object or folder out of Lumen provides both the private Lumen cloud payload and an asynchronous file representation. Internal drops continue to organize cloud objects. External Finder drops download into a cache-backed promised item and publish the expected filename only after completion.

One selected object exports as that file. One selected folder exports as that folder tree. Multiple selected items export as a folder named `Lumen 下载`, with Finder-style collision-safe local names. The drag preview reflects the selection count. Cancelling the Finder promise cancels its downloads; abandoned cache exports are pruned on the next launch.

The same download planning and path-safety rules serve explicit downloads, Quick Look, and promised-file export so the three paths cannot disagree about traversal or collisions.

## Versions and Recovery

For a selected object, `版本历史…` opens a native table showing version date, size, storage class, current-version state, and delete markers. The view can Quick Look or download a historical version.

`恢复此版本` copies the selected historical version to the same key, creating a new current version and retaining history. `恢复已删除项目` removes the exact current delete marker. Permanently deleting a historical version is intentionally excluded from 0.0.9 because recovery should be forgiving.

Buckets without versioning show a precise empty state rather than an error. Partial or repeated-token version listings are marked incomplete. Version actions refresh the current folder, search cache, smart locations, and information sheet.

## Cross-Bucket Organization

Cloud drag and paste accept a source Bucket different from the current destination Bucket when both accounts are available locally.

- Same account and same region use destination-scoped server-side `CopyObject` with an explicit source Bucket and preserve metadata/tags by default.
- Same account across regions, or different local accounts, uses a relay: range-download each source object to an owned temporary file, verify it when possible, then upload it to the destination with the destination account's policy.
- Move always completes every copy before deleting any source. A failed copy never deletes its source.
- A preflight sheet states source, destination, item count, known bytes, and `云端复制` or `经由这台 Mac`. The relay method warns that network transfer may incur time and traffic charges.
- Destination collisions follow the configured Ask/Skip/Replace/Keep Both policy.

Folder mappings preserve exact relative keys. Cross-Bucket operations are recorded in the transfer center; a move can be undone only while the source remains recoverable and the exact reverse operation is safe.

## Object Properties and Tags

`对象属性…` opens for exactly one object and edits:

- Content-Type;
- Cache-Control;
- Content-Disposition filename;
- user metadata keys beginning with `x-oss-meta-`;
- up to ten OSS tag key/value pairs.

Existing values load before editing. Validation is inline: blank/duplicate keys, invalid header values, and tag limits prevent Save without discarding the draft. Saving standard/user metadata performs a same-object copy with metadata replacement and preserves unedited properties; saving tags uses the tagging API. If only tags changed, metadata is not rewritten. The UI explains that changing metadata in a version-enabled Bucket creates a new version.

ACL, storage-class conversion, encryption, retention, and lifecycle are read-only or excluded because they carry broader access, cost, and compliance consequences.

## Settings and Links

Settings keeps the existing General, Transfers, and Accounts tabs.

General adds:

- new-window behavior: inherit focused location (default) or open last location;
- signed-link lifetime: 1 hour, 1 day, or 7 days;
- default download location: Ask Every Time or Downloads.

Transfers adds:

- upload concurrency and download concurrency;
- upload and download speed limits;
- default conflict policy;
- completion sound, menu-bar status, and completion notification;
- `打开传输窗口` and history clearing.

All settings use native Form controls, persist in `UserDefaults`, and have safe defaults matching 0.0.8 behavior where possible. Signed-link generation reads the configured lifetime everywhere, including plain, Markdown, and HTML copies.

## Architecture and Boundaries

The large existing `AppModel` and `BrowserView` files are split only along new behavior boundaries:

- `BucketSearchController` owns remote search state, cache keys, cancellation, and smart queries;
- `TransferCheckpoint` and `TransferJournal` own durable resume data;
- `TransferEngine` owns queue policy and job lifecycle, while `OSSClient` owns OSS multipart/range protocol details;
- `FinderExportCoordinator` owns item providers and cache cleanup;
- `VersionHistoryModel` owns version listing and recovery;
- `ObjectPropertiesModel` owns editable metadata/tag drafts and validation;
- cross-Bucket planning uses value types independent of UI before AppModel executes it;
- focused command actions expose windows and sheets without coupling them to toolbar layout.

No new third-party runtime dependency is introduced. Existing Sparkle and Swift package pins remain unchanged.

## Failure, Safety, and Privacy

- No credential, signed URL, local path, Bucket name, object key, metadata value, or tag value enters diagnostics unless the user explicitly copies that field.
- Search and smart-location network work cancels on account/Bucket change and stale results cannot overwrite a new location.
- Source-file identity is validated before upload resume.
- Partial downloads are scoped beneath validated roots and atomically renamed only after completion.
- Cross-Bucket move is copy-first and source deletion is exact.
- Version restore uses the exact version ID or delete-marker ID.
- Metadata drafts survive a failed Save and show the OSS request ID when available.
- Notification permission is requested only from an explicit setting change.
- Reduced Motion removes custom movement from transfer and search transitions while retaining opacity/status feedback.

## Documentation and Release

- Marketing version becomes `0.0.9`; build becomes `9` everywhere.
- README, help, website, support/privacy download links, release notes, update feed, and package scripts use 0.0.9.
- README leads with the Finder workflow and explains search, resumable transfers, Finder drag-out, versions, properties, and cross-Bucket behavior without reading like a feature dump.
- Synthetic browser and account screenshots remain exactly 2480 × 1600 pixels. The browser fixture shows Bucket-search results and the compact transfer summary; no production identifiers appear.
- The public release contains `Lumen-0.0.9.dmg`, release notes, and the updated appcast.
- After publication, the released DMG and appcast are downloaded again, checked against the published digests and version, installed to `/Applications/Lumen.app`, launched, and verified as 0.0.9 (9).

## Verification

Completion requires:

- test-first regression coverage for search cancellation/pagination/filtering, upload and download checkpoint persistence, pause/resume/cancel, queue priority, conflicts, version XML/recovery, metadata/tag XML and validation, cross-Bucket copy safety, Finder provider planning, settings persistence, and stale-response isolation;
- the complete macOS test suite with no failures; the real OSS smoke test remains opt-in;
- Release build, static analysis, shell/plist/XML/YAML checks, website validation, and `git diff --check`;
- interactive inspection of search, transfer, version/property sheets, tabs, drag-out, light/dark mode, keyboard access, and reduced-motion behavior when the desktop session is available;
- 2480 × 1600 synthetic screenshot inspection;
- pull-request checks, merged-main checks, Pages deployment, release-asset/appcast verification, update discovery, and local installed-version verification.

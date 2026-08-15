# Lumen 0.0.9 Durable Transfers and Finder Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Repository instructions prohibit subagent creation without separate user approval. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make uploads and downloads pauseable and recoverable, expose a native transfer window, and let cloud selections be dragged to Finder.

**Architecture:** Persist protocol-level checkpoints beside retry descriptors in `TransferJournal`. `OSSClient` resumes multipart uploads and range downloads; `TransferEngine` owns state transitions, policies, queue order, throttling, and estimates. Finder export supplies an `NSItemProvider` backed by the same safe download planner, so explicit download and drag-out share collision and path rules.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, UniformTypeIdentifiers, Swift Testing, OSS multipart and Range APIs.

## Global Constraints

- Pause preserves recoverable state; Cancel removes local partials and aborts remote multipart uploads.
- Completed destinations are published atomically and never overwrite silently.
- Source identity is validated before upload resume.
- Transfer journal decoding remains compatible with 0.0.8 records.
- Speed and remaining-time values never affect correctness.
- Finder export caches contain no credential material and are pruned.

---

### Task 1: Checkpoint and Policy Models

**Files:**
- Create: `Lumen/Transfer/TransferCheckpoint.swift`
- Modify: `Lumen/Transfer/TransferJob.swift`
- Modify: `Lumen/Transfer/TransferJournal.swift`
- Modify: `Lumen/App/AppSettings.swift`
- Modify: `LumenTests/TransferEngineTests.swift`
- Modify: `LumenTests/AppModelTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `MultipartUploadCheckpoint`, `RangeDownloadCheckpoint`, and `TransferCheckpoint`.
- Adds: `TransferStatus.paused`, `TransferConflictPolicy`, `TransferSpeedLimit`, `DownloadLocation`, and `SignedLinkLifetime`.
- Adds optional `checkpoint` to `PersistedTransfer`; missing JSON keys decode as nil.

- [ ] **Step 1: Write failing journal compatibility and setting tests**

Decode a literal 0.0.8 transfer JSON record without `checkpoint` and assert nil. Round-trip a multipart checkpoint containing upload ID and two ETags. Assert paused jobs are not active and are resumable. Persist and reload each settings enum through isolated `UserDefaults`.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-transfer -only-testing:LumenTests/TransferEngineTests -only-testing:LumenTests/AppModelTests test
```

Expected: compilation fails for the new models.

- [ ] **Step 3: Implement Codable models and safe defaults**

Use 8 MiB as both multipart and download-range checkpoint granularity. Default conflict to Ask, speed to Unlimited, download location to Ask, signed link lifetime to one hour, and download concurrency to 3. Keep upload concurrency mapped from the existing key.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: focused tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Transfer/TransferCheckpoint.swift Lumen/Transfer/TransferJob.swift Lumen/Transfer/TransferJournal.swift Lumen/App/AppSettings.swift LumenTests/TransferEngineTests.swift LumenTests/AppModelTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: persist resumable transfer state"
```

### Task 2: Resumable Multipart Upload Protocol

**Files:**
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `LumenTests/OSSClientTests.swift`

**Interfaces:**
- Extends `putObject` with optional checkpoint input and checkpoint callback.
- Produces: `abortMultipartUpload(_:) async`.

- [ ] **Step 1: Write failing multipart resume tests**

Build a transport fixture that initiates upload `u-1`, accepts part 1 and part 2, then completes. Assert checkpoint callbacks contain literal ETags after each part. Supply a checkpoint with part 1 complete and assert no request for part 1 occurs. Supply a checkpoint with wrong size or key and assert a new upload is initiated. Assert cancellation preserves the callback checkpoint while explicit abort sends one DELETE.

- [ ] **Step 2: Run OSS tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-transfer -only-testing:LumenTests/OSSClientTests test
```

Expected: existing automatic-abort behavior fails the new contract.

- [ ] **Step 3: Implement checkpoint validation and missing-part upload**

Capture source modification date and size before starting. Reuse a checkpoint only when Bucket, key, size, modification date, and part size match. Sort completed parts by number before completing. Send a checkpoint callback after initiation and every part, then nil after a verified completion. Move remote abort out of generic error handling and into explicit cancellation policy.

- [ ] **Step 4: Run OSS tests and verify GREEN**

Run the Step 2 command. Expected: all OSS tests pass after replacing the old automatic-abort expectation with explicit abort coverage.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/OSSClient.swift LumenTests/OSSClientTests.swift
git commit -m "feat: resume multipart uploads"
```

### Task 3: Range-Checkpointed Downloads

**Files:**
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/OSS/OSSTypes.swift`
- Modify: `LumenTests/OSSClientTests.swift`

**Interfaces:**
- Produces: `downloadResumable(key:to:within:expectedSize:checkpoint:onCheckpoint:onProgress:)`.
- `ObjectHead` adds optional `crc64`.

- [ ] **Step 1: Write failing byte-range and atomic-publication tests**

Use a literal 20 MiB object fixture. Assert requests use ranges `0-8388607`, `8388608-16777215`, and `16777216-20971519`; checkpoint byte counts advance only after each complete range. Seed an 8 MiB partial checkpoint and assert only the final two requests occur. Inject a CRC mismatch and assert destination is absent while the partial remains recoverable. Assert an existing destination fails before any network request.

- [ ] **Step 2: Run OSS tests and verify RED**

Run Task 2's focused command. Expected: compilation fails for `downloadResumable` and `ObjectHead.crc64`.

- [ ] **Step 3: Implement bounded range download**

Write each response Data to an owned hidden partial using `FileHandle` append, fsync, then emit the checkpoint. Validate 206 for nonzero offsets and exact response length. On completion, compare full-file CRC64 when HEAD supplies it, create destination parents, revalidate root containment, and move the partial atomically.

- [ ] **Step 4: Run OSS tests and verify GREEN**

Run Task 2's command. Expected: all OSS tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/OSSClient.swift Lumen/OSS/OSSTypes.swift LumenTests/OSSClientTests.swift
git commit -m "feat: resume downloads by byte range"
```

### Task 4: Transfer Engine State Machine and Queue Controls

**Files:**
- Modify: `Lumen/Transfer/TransferEngine.swift`
- Modify: `Lumen/Transfer/TransferJournal.swift`
- Modify: `LumenTests/TransferEngineTests.swift`

**Interfaces:**
- Produces: `pause(_:)`, `resume(_:)`, `pauseAll()`, `resumeAll()`, `cancel(_:)`, and `moveToTop(_:)`.
- Produces computed `currentBytesPerSecond(_:)` and `estimatedRemaining(_:)`.

- [ ] **Step 1: Write failing transition and queue tests**

Assert running to paused preserves checkpoint and retry descriptor; paused to resumed reuses the exact object key/destination; Cancel removes a partial and invokes multipart abort once; restore changes an interrupted job with a valid checkpoint to paused; invalid bookmark remains failed with a reason; move-to-top reorders only queued jobs. Feed literal timestamp/byte samples and assert a stable moving-average rate and remaining time after three samples.

- [ ] **Step 2: Run transfer tests and verify RED**

Run Task 1's focused command limited to `TransferEngineTests`. Expected: compilation fails for the state methods.

- [ ] **Step 3: Implement state transitions and persistence**

Track a per-job user intent (`pause` or `cancel`) so task cancellation maps correctly. Persist checkpoint callbacks immediately. Use separate upload/download running counts and limits. Keep queued job order in `jobs`; `waitForSlot` checks both order and direction capacity. Throttle after completed parts/ranges using elapsed bytes against the configured per-direction ceiling.

- [ ] **Step 4: Run transfer tests and verify GREEN**

Run the focused command. Expected: all transfer tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Transfer/TransferEngine.swift Lumen/Transfer/TransferJournal.swift LumenTests/TransferEngineTests.swift
git commit -m "feat: pause and resume transfers"
```

### Task 5: Conflict Planning and Download Defaults

**Files:**
- Create: `Lumen/Transfer/TransferConflictPlanner.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Support/FileSafety.swift`
- Modify: `LumenTests/TransferEngineTests.swift`
- Modify: `LumenTests/SafetyAndVersionTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: collision result `replace`, `skip`, or `renamed(key:)`.
- Produces Finder-style `name 2.ext`, `name 3.ext` key and local filename generation.

- [ ] **Step 1: Write failing conflict and local-name tests**

Assert Keep Both maps `hero.png` to `hero 2.png` when the original exists and to `hero 3.png` when both exist; folders use `Folder 2/`; extensionless names remain valid. Assert Ask creates one batch prompt, Skip removes all conflicts, and Replace retains exact keys. Assert Downloads mode selects the user Downloads directory without opening a panel.

- [ ] **Step 2: Run focused tests and verify RED**

Run Task 1's focused command. Expected: compilation fails for the planner.

- [ ] **Step 3: Implement pure conflict planning and integrate upload/download entry points**

Perform existence checks before enqueueing, apply one configured policy to the batch, and preserve the current confirmation dialog only for Ask. Use `FileManager.url(for:.downloadsDirectory,...)` for Downloads mode and retain the open panel for Ask.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run Task 1's command. Expected: focused tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Transfer/TransferConflictPlanner.swift Lumen/App/AppModel.swift Lumen/Support/FileSafety.swift LumenTests/TransferEngineTests.swift LumenTests/SafetyAndVersionTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: add transfer conflict policies"
```

### Task 6: Native Transfer Window and Settings

**Files:**
- Create: `Lumen/Views/TransferWindow.swift`
- Modify: `Lumen/Views/TransferTray.swift`
- Modify: `Lumen/Views/SettingsView.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `Lumen/App/AppServices.swift`
- Modify: `LumenTests/AppModelTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Adds Window scene id `transfers` and shared `TransferFilter` selection.
- The compact tray exposes summary, Pause All/Resume All, and Open Transfers.

- [ ] **Step 1: Write failing filter and action availability tests**

For a mixed literal job list, assert each filter returns exact IDs and that Pause All excludes queued/paused jobs while Resume All includes only paused jobs. Assert Reveal is available only for a completed download with a resolved local URL.

- [ ] **Step 2: Run focused tests and verify RED**

Run Task 1's command. Expected: compilation fails for `TransferFilter`.

- [ ] **Step 3: Build the transfer window**

Use a native segmented filter, Table rows, linear progress, monospaced byte/rate/ETA labels, and contextual row buttons. Keep destructive Cancel separated in menus. Use opacity transitions under Reduce Motion. Add `Command-Option-L` to open the window.

- [ ] **Step 4: Expand Transfers settings**

Add independent concurrency steppers, direction speed menus, conflict policy, default download destination, completion notification, and Open Transfers. Request `UNUserNotificationCenter` authorization only in the toggle's false-to-true change handler; turn the toggle back off on denial.

- [ ] **Step 5: Run focused tests and build**

Run Task 1's command, then a normal build with `.build/v009-transfer`. Expected: tests and build succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Views/TransferWindow.swift Lumen/Views/TransferTray.swift Lumen/Views/SettingsView.swift Lumen/LumenApp.swift Lumen/App/AppServices.swift LumenTests/AppModelTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: add native transfer center"
```

### Task 7: Finder Promised-File Export

**Files:**
- Create: `Lumen/Transfer/FinderExportCoordinator.swift`
- Modify: `Lumen/OSS/CloudObjectOperation.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Create: `LumenTests/FinderExportTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `FinderExportPlan` and `FinderExportCoordinator.itemProvider(for:)`.
- Makes `.lumenCloudItems` internal so one provider advertises cloud data plus file representation.

- [ ] **Step 1: Write failing export-plan tests**

Assert one object exports its filename, one folder exports its tree root, and multiple selections export under `Lumen 下载`. Assert traversal keys are rejected and duplicate leaf names become Finder-style numbered names. Assert cache pruning removes only owned exports older than 24 hours.

- [ ] **Step 2: Run Finder export tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-transfer -only-testing:LumenTests/FinderExportTests test
```

Expected: compilation fails for export types.

- [ ] **Step 3: Implement provider and shared download execution**

Register the JSON cloud payload for internal drop and a file representation for Finder. Build exports beneath `Caches/studio.lumen.oss/FinderExports/<UUID>`, download with `downloadResumable`, and call the item-provider completion only after the promised root exists. Return a cancellation progress object that cancels the Task.

- [ ] **Step 4: Replace item drags and verify internal drops remain compatible**

Use `.onDrag` with the combined provider and the existing preview. Keep `.dropDestination(for: CloudDragPayload.self)` unchanged. For multiple selection, provider planning uses the actionable visible selection exactly as cloud clipboard does.

- [ ] **Step 5: Run export, browser, and transfer tests plus build**

Run Finder export tests, `BrowserModelTests`, `TransferEngineTests`, and a normal build. Expected: all succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Transfer/FinderExportCoordinator.swift Lumen/OSS/CloudObjectOperation.swift Lumen/App/AppModel.swift Lumen/Views/BrowserView.swift LumenTests/FinderExportTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: drag OSS items to Finder"
```


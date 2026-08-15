# Lumen 0.0.9 Cloud Safety Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Repository instructions prohibit subagent creation without separate user approval. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add object version recovery, metadata/tag editing, and safe cross-Bucket copy/move.

**Architecture:** Extend XML/types/client APIs with testable value boundaries. Dedicated observable sheet models load and save versions/properties while `AppModel` only presents and routes them. Cross-Bucket planning is pure, selects server-side or relay execution explicitly, and preserves copy-before-delete safety.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, OSS versioning, CopyObject, tagging, and metadata APIs.

## Global Constraints

- Historical versions are restored, never permanently deleted.
- Cross-Bucket move deletes no source until every copy succeeds.
- Metadata/tag drafts survive failed saves.
- Cross-region/account relay is explicit and visible before execution.
- No Bucket configuration, ACL mutation, storage conversion, lifecycle, or retention editing is added.

---

### Task 1: Version Types, XML, and Paging API

**Files:**
- Create: `Lumen/OSS/OSSVersioning.swift`
- Modify: `Lumen/OSS/OSSXML.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `LumenTests/OSSClientTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `OSSObjectVersion`, `OSSDeleteMarkerVersion`, `OSSVersionPage`, and `OSSVersionListing`.
- Produces: `listObjectVersions(prefix:keyMarker:versionIDMarker:)`, `listAllVersions(prefix:)`, and `restoreVersion(key:versionID:)`.

- [ ] **Step 1: Write failing literal XML parsing tests**

Parse a fixture containing one current version, one historical version, one delete marker, `NextKeyMarker`, and `NextVersionIdMarker`. Assert exact IDs, dates, sizes, current flags, and markers. Add a truncated response missing one marker and assert aggregate listing is incomplete without looping.

- [ ] **Step 2: Run OSS tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-cloud -only-testing:LumenTests/OSSClientTests test
```

Expected: compilation fails for version types/APIs.

- [ ] **Step 3: Implement parser and paged API**

Use query `versions`, optional prefix, key-marker, and version-id-marker. Treat both markers as a pagination pair. `restoreVersion` sends `CopyObject` with a percent-encoded source `versionId` and copies to the same key.

- [ ] **Step 4: Add request-level restore tests and verify GREEN**

Assert the restore request contains the exact encoded source Bucket/key/version and no DELETE. Run the Step 2 command. Expected: all OSS tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/OSSVersioning.swift Lumen/OSS/OSSXML.swift Lumen/OSS/OSSClient.swift LumenTests/OSSClientTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: read and restore object versions"
```

### Task 2: Version History and Deleted Objects UI

**Files:**
- Create: `Lumen/Browser/VersionHistoryModel.swift`
- Create: `Lumen/Views/VersionHistoryView.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/Views/SidebarView.swift`
- Create: `LumenTests/VersionHistoryTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: load, restore-version, restore-delete-marker, historical download, and Quick Look actions.
- Deleted smart location filters delete markers and groups by object key.

- [ ] **Step 1: Write failing state and exact-recovery tests**

With a fake page loader, assert versions are newest first, current version is labeled, and the model retains an incomplete marker. Assert restoring a version sends that exact version ID; restoring a deleted object deletes only the selected delete-marker version ID; stale loads do not replace a newer object.

- [ ] **Step 2: Run version tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-cloud -only-testing:LumenTests/VersionHistoryTests test
```

Expected: compilation fails for the model.

- [ ] **Step 3: Implement model and native sheet**

Use a Table with Date, Size, Storage, and Status. Put Restore as the primary contextual action, Download/Quick Look alongside it, and keep no permanent-delete action. Add empty copy explaining that versioning must already be enabled in OSS.

- [ ] **Step 4: Integrate menus and deleted smart location**

Add `版本历史…` only for exactly one object. Route the sidebar Deleted location to the same model with the whole Bucket prefix and marker-only mode. Refresh browser/search caches after successful recovery.

- [ ] **Step 5: Run version tests and build**

Run the Step 2 command and a normal build. Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Browser/VersionHistoryModel.swift Lumen/Views/VersionHistoryView.swift Lumen/App/AppModel.swift Lumen/Views/BrowserView.swift Lumen/Views/RootView.swift Lumen/Views/SidebarView.swift LumenTests/VersionHistoryTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: recover historical and deleted objects"
```

### Task 3: Object Metadata and Tag Protocols

**Files:**
- Create: `Lumen/OSS/OSSObjectProperties.swift`
- Modify: `Lumen/OSS/OSSTypes.swift`
- Modify: `Lumen/OSS/OSSXML.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `LumenTests/OSSClientTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Extends `ObjectHead` with cacheControl, contentDisposition, userMetadata, and crc64.
- Produces: `OSSObjectTag`, `getObjectTags(key:)`, `putObjectTags(key:tags:)`, and `replaceMetadata(key:properties:)`.

- [ ] **Step 1: Write failing HEAD, tag XML, and self-copy tests**

Assert case-insensitive response headers map into exact standard and `x-oss-meta-*` values. Parse two literal tags including encoded spaces. Assert tag PUT escapes XML special characters. Assert metadata replace self-copies with `x-oss-metadata-directive: REPLACE`, exact content headers, and preserved user metadata.

- [ ] **Step 2: Run OSS tests and verify RED**

Run Task 1's OSS command. Expected: compilation fails for properties APIs.

- [ ] **Step 3: Implement property types and client methods**

Normalize user metadata keys to lowercase `x-oss-meta-` headers. Use GET/PUT with `tagging` query. Limit parser output to ten tags and throw a validation error for malformed duplicates. Metadata replacement uses the exact current Bucket/key as copy source.

- [ ] **Step 4: Run OSS tests and verify GREEN**

Run Task 1's command. Expected: all OSS tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/OSSObjectProperties.swift Lumen/OSS/OSSTypes.swift Lumen/OSS/OSSXML.swift Lumen/OSS/OSSClient.swift LumenTests/OSSClientTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: read and write object properties"
```

### Task 4: Object Properties Editor

**Files:**
- Create: `Lumen/Browser/ObjectPropertiesModel.swift`
- Create: `Lumen/Views/ObjectPropertiesView.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Modify: `Lumen/Views/RootView.swift`
- Create: `LumenTests/ObjectPropertiesTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces editable `ObjectPropertiesDraft` with `validationErrors` and dirty-section detection.
- Saves metadata and tags independently so an unchanged section creates no request.

- [ ] **Step 1: Write failing validation and selective-save tests**

Assert blank/duplicate user keys, CR/LF header injection, duplicate tag keys, and eleven tags are invalid. Assert changing only tags calls only tag save; changing only Content-Type calls only metadata save; failed saves preserve the draft and expose request ID.

- [ ] **Step 2: Run properties tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-cloud -only-testing:LumenTests/ObjectPropertiesTests test
```

Expected: compilation fails for the editor model.

- [ ] **Step 3: Implement model and native editor sheet**

Use grouped Form sections for Web Behavior, User Metadata, and Tags. Use editable rows with minus buttons and one Add action per collection. Show the versioning note beneath Save, keep Cancel/default keyboard actions, and disable Save during load/save or validation failure.

- [ ] **Step 4: Integrate selected-object command and refresh**

Expose `对象属性…` from context menu and information sheet for exactly one object. On success refresh listing, information, search cache, and version history.

- [ ] **Step 5: Run tests and build**

Run Step 2 and a normal build. Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Browser/ObjectPropertiesModel.swift Lumen/Views/ObjectPropertiesView.swift Lumen/App/AppModel.swift Lumen/Views/BrowserView.swift Lumen/Views/RootView.swift LumenTests/ObjectPropertiesTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: edit object metadata and tags"
```

### Task 5: Cross-Bucket Planning and Server-Side Copy

**Files:**
- Create: `Lumen/OSS/CrossBucketOperation.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/OSS/CloudObjectOperation.swift`
- Modify: `LumenTests/OSSClientTests.swift`
- Create: `LumenTests/CrossBucketOperationTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CrossBucketMethod.serverSide` or `.relay`, preflight summary, and exact source/destination mappings.
- Extends copy API with explicit source Bucket and optional source version.

- [ ] **Step 1: Write failing method-selection and mapping tests**

Assert same account/region selects server-side, different region or account selects relay, folder relative keys are preserved, duplicate destinations fail, and known bytes sum without overflow. Assert explicit-source copy signs for destination Bucket while its header references the encoded source Bucket/key.

- [ ] **Step 2: Run cross-Bucket and OSS tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-cloud -only-testing:LumenTests/CrossBucketOperationTests -only-testing:LumenTests/OSSClientTests test
```

Expected: compilation fails for the planner and explicit-source copy.

- [ ] **Step 3: Implement pure preflight planning and client copy**

The planner consumes source/destination account IDs, Buckets, payload keys, expanded folder mappings, and conflict results. It returns method, item count, known bytes, and mappings. The client method keeps metadata and tags with COPY directives.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run Step 2. Expected: focused tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/CrossBucketOperation.swift Lumen/OSS/OSSClient.swift Lumen/OSS/CloudObjectOperation.swift LumenTests/OSSClientTests.swift LumenTests/CrossBucketOperationTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: plan cross-Bucket operations"
```

### Task 6: Cross-Bucket Execution and Preflight UI

**Files:**
- Create: `Lumen/Views/CrossBucketPreflightView.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Lumen/Transfer/TransferEngine.swift`
- Modify: `LumenTests/AppModelTests.swift`
- Modify: `LumenTests/TransferEngineTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Adds pending preflight state to AppModel and confirmed execution to TransferEngine.
- Relay uses owned temporary files and existing resumable download/upload methods.

- [ ] **Step 1: Write failing copy-before-delete tests**

Assert a three-item move with second copy failure performs zero source deletes. Assert full copy success deletes the three exact source keys. Assert relay cleans owned temporary files on success/cancel and preserves source on upload failure. Assert same-Bucket path still uses the existing fast path.

- [ ] **Step 2: Run focused tests and verify RED**

Run Task 5's command plus `AppModelTests` and `TransferEngineTests`. Expected: cross-Bucket payload is currently rejected.

- [ ] **Step 3: Implement preflight and server-side execution**

Resolve source account/Bucket from the payload, expand folders with the source client, run conflict planning, and present one sheet naming source, destination, count, known size, and method. Server-side mode copies all mappings, then deletes sources only for Move after full success.

- [ ] **Step 4: Implement relay execution**

Create owned temporary files, enqueue a linked download/upload chain per mapping under one parent transfer summary, and defer all source deletion until every child completes. Apply destination account ACL and configured speed/concurrency policies.

- [ ] **Step 5: Run focused tests and build**

Run Step 2's suites and a normal build. Expected: all succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Views/CrossBucketPreflightView.swift Lumen/App/AppModel.swift Lumen/Views/RootView.swift Lumen/Transfer/TransferEngine.swift LumenTests/AppModelTests.swift LumenTests/TransferEngineTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: organize objects across Buckets"
```


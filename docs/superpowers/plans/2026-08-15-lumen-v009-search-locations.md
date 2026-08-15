# Lumen 0.0.9 Search and Locations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Repository instructions prohibit subagent creation without separate user approval. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cancellable current-Bucket search, filters, result navigation, and contextual smart locations without weakening current-folder filtering.

**Architecture:** Introduce pure query/result types and an observable `BucketSearchController` that consumes an OSS page loader. `OSSClient` exposes one recursive object page at a time; the controller owns pagination, filtering, cache, progress, cancellation, and stale-result isolation. `BucketSearchView` and sidebar smart locations consume only controller state and route navigation back through `AppModel`.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation, Swift Testing, OSS ListObjectsV2.

## Global Constraints

- Current-folder search remains local and instantaneous.
- Current-Bucket search never issues per-result HEAD requests.
- Every paged search detects missing or repeated continuation tokens and marks results incomplete.
- Account/Bucket changes cancel the search and stale responses cannot commit.
- Search results never include folder placeholders as files.
- No new runtime dependency is introduced.

---

### Task 1: Search Query, Filter, and Cache Value Types

**Files:**
- Create: `Lumen/Browser/BucketSearchTypes.swift`
- Create: `LumenTests/BucketSearchTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `BucketSearchScope`, `BucketSearchKind`, `BucketSearchDateRange`, `BucketSearchFilter`, `BucketSearchQuery`, `BucketSearchProgress`, `BucketSearchSnapshot`, and `SmartLocation`.
- `BucketSearchQuery.matches(_:) -> Bool` performs locale-aware key matching and value-filter checks.

- [ ] **Step 1: Write failing pure behavior tests**

Add literal fixtures proving that `assets/Hero.PNG` matches `hero` with image kind, that a 120 MB object matches the large threshold, that an old object fails the recent-seven-days range, and that a folder placeholder never matches. Add an equality/hash test proving two queries that differ by Bucket or size range do not share a cache key.

```swift
@Test func queryMatchesFullKeyCaseInsensitivelyAndAppliesFilters() {
    let query = BucketSearchQuery(
        accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        bucketName: "demo",
        text: "hero",
        filter: BucketSearchFilter(kind: .images, minimumSize: 100, maximumSize: nil, modified: .any)
    )
    let object = OSSObject(key: "assets/Hero.PNG", size: 200, etag: "e", lastModified: .now, storageClass: "Standard")
    #expect(query.matches(object))
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-search -only-testing:LumenTests/BucketSearchTests test
```

Expected: compilation fails because the search types do not exist.

- [ ] **Step 3: Implement the value types**

Use `localizedStandardContains` behavior through `range(of:options:locale:)` with `.caseInsensitive`, `.diacriticInsensitive`, and `.widthInsensitive`. Treat nil modified dates as non-matching only when a date filter is active. Define smart queries as `.recent(days: 7)`, `.large(minimumBytes: 100 * 1_024 * 1_024)`, `.deleted`, and `.failedTransfers`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: all `BucketSearchTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Browser/BucketSearchTypes.swift LumenTests/BucketSearchTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: define Bucket search queries"
```

### Task 2: Recursive Page API and Pagination Safety

**Files:**
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/OSS/OSSTypes.swift`
- Modify: `LumenTests/OSSClientTests.swift`

**Interfaces:**
- Produces: `OSSClient.listObjectPage(prefix:token:) async throws -> ObjectListing` with no delimiter.
- Existing `listAllObjects` delegates to the page method and preserves its 30-page safety cap.

- [ ] **Step 1: Write failing request and token tests**

Add a recording transport fixture with two literal XML pages. Assert the first request contains `list-type=2`, `max-keys=1000`, and no `delimiter`; the second uses the exact encoded continuation token. Add a malformed truncated page with no next token and assert the aggregate reports `truncated == true` without looping.

- [ ] **Step 2: Run the focused OSS tests and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-search -only-testing:LumenTests/OSSClientTests test
```

Expected: compilation fails for `listObjectPage`.

- [ ] **Step 3: Implement the page API and refactor aggregation**

Build the query with `list-type`, `max-keys`, optional prefix, and optional continuation token. Parse through the existing `OSSXML.listing`, remove only placeholders according to the caller's aggregate option, and keep repeated-token detection in the aggregate loop.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Step 2 command. Expected: all `OSSClientTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/OSS/OSSClient.swift Lumen/OSS/OSSTypes.swift LumenTests/OSSClientTests.swift
git commit -m "feat: expose safe recursive object pages"
```

### Task 3: Cancellable Bucket Search Controller

**Files:**
- Create: `Lumen/Browser/BucketSearchController.swift`
- Modify: `LumenTests/BucketSearchTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `@MainActor @Observable final class BucketSearchController`.
- Produces: `search(query:pageLoader:)`, `cancel()`, `clear()`, and `invalidate(accountID:bucketName:)`.
- Page loader signature: `@Sendable (String?) async throws -> ObjectListing`.

- [ ] **Step 1: Write failing pagination, progress, cache, and stale tests**

Use an actor-backed loader returning two pages. Assert objects are emitted sorted by the requested smart-location rule, scanned count is 3, matched count is 2, and the final snapshot is complete. Add a repeated token page and assert incomplete. Start a suspended first query, begin a second query, release the first, and assert only the second query commits. Run the same completed query twice and assert the loader is called only for the first run.

- [ ] **Step 2: Run `BucketSearchTests` and verify RED**

Use the Task 1 command. Expected: compilation fails for `BucketSearchController`.

- [ ] **Step 3: Implement controller state and cache**

Keep `results`, `progress`, `isSearching`, `errorMessage`, `activeQuery`, and `snapshot` observable. Store an incrementing generation and compare it after every await. Limit collection to 30 pages and 30,000 scanned objects, check `Task.isCancelled`, and cache only successful snapshots. Keep the cache bounded to eight snapshots with least-recently-used eviction.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Task 1 command. Expected: all search tests pass.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Browser/BucketSearchController.swift LumenTests/BucketSearchTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: add cancellable Bucket search"
```

### Task 4: Search Integration and Result Navigation

**Files:**
- Create: `Lumen/Views/BucketSearchView.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `LumenTests/AppModelTests.swift`
- Modify: `Lumen.xcodeproj/project.pbxproj`

**Interfaces:**
- `AppModel.searchScope`, `searchFilter`, and shared `searchController` drive the view.
- `AppModel.runBucketSearch()` captures the selected account/Bucket and scoped client.
- `AppModel.openSearchResult(_:)` navigates to the object's parent prefix and selects its key after refresh.

- [ ] **Step 1: Write failing stale-scope and navigation tests**

Assert a Bucket search request captures the current account/Bucket and that selecting `art/hero.png` navigates to `art/` and selects the exact key. Assert switching Bucket clears results and cancels a suspended loader.

- [ ] **Step 2: Run `AppModelTests` and verify RED**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-search -only-testing:LumenTests/AppModelTests test
```

Expected: compilation fails for the search integration methods.

- [ ] **Step 3: Implement AppModel integration**

Add search cancellation to the existing request invalidation paths. Debounce non-empty Bucket queries by 250 ms in the view task, but make explicit filter changes run immediately. Invalidate the selected Bucket cache after upload, delete, rename, move, copy, restore, or property save.

- [ ] **Step 4: Build the native result UI**

Keep `.searchable` in the toolbar. When search is active, show an adjacent scope picker and filter popover. Render Bucket results in a `Table` with Name, Location, Size, and Modified columns; include progress and Cancel in a compact status row. Double-click calls `openSearchResult`; Space uses the existing Quick Look download path for that result. Use `ContentUnavailableView` for no results and precise incomplete/error labels.

- [ ] **Step 5: Run focused tests and build**

Run the Step 2 command, then:

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/v009-search build
```

Expected: focused tests and build succeed.

- [ ] **Step 6: Commit**

```bash
git add Lumen/Views/BucketSearchView.swift Lumen/App/AppModel.swift Lumen/Views/BrowserView.swift Lumen/Views/RootView.swift LumenTests/AppModelTests.swift Lumen.xcodeproj/project.pbxproj
git commit -m "feat: search the current Bucket"
```

### Task 5: Sidebar Smart Locations

**Files:**
- Modify: `Lumen/Views/SidebarView.swift`
- Modify: `Lumen/Views/BucketSearchView.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `LumenTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppModel.openSmartLocation(_:)`.
- `.recent` and `.large` translate to empty-text search queries with filters.
- `.failedTransfers` opens the transfer window through a closure added in the later transfer plan; until then it sets the requested filter in shared services.

- [ ] **Step 1: Write failing smart-query mapping tests**

Freeze `now` at a literal date. Assert Recent uses exactly seven days, Large uses exactly 104,857,600 bytes, and each Bucket-backed location refuses to open without a selected Bucket.

- [ ] **Step 2: Run focused tests and verify RED**

Run the Task 4 focused command. Expected: compilation fails for `openSmartLocation`.

- [ ] **Step 3: Implement location routing and sidebar section**

Add a `位置` section above accounts using `clock`, `externaldrive.badge.plus`, `trash`, and `exclamationmark.arrow.triangle.2.circlepath` symbols. Recent and Large activate `BucketSearchView` with a visible smart-location title and no editable text requirement. Deleted defers to `VersionHistoryModel` from the cloud-safety plan through an enum state rather than duplicating version loading.

- [ ] **Step 4: Run focused tests, build, and inspect diff**

Run the Task 4 test and build commands, followed by `git diff --check`.

- [ ] **Step 5: Commit**

```bash
git add Lumen/Views/SidebarView.swift Lumen/Views/BucketSearchView.swift Lumen/App/AppModel.swift LumenTests/AppModelTests.swift
git commit -m "feat: add contextual smart locations"
```


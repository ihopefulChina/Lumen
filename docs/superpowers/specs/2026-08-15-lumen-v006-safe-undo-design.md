# Lumen 0.0.6 Safe Undo Design

## Objective

Ship Lumen 0.0.6 as a focused Finder-trust release: users can safely undo the latest successful rename or same-Bucket move without silent overwrite, while every unsupported destructive action remains explicitly irreversible.

The release version is `0.0.6`, the bundle build number is `6`, and the public artifact is `Lumen-0.0.6.dmg` for Apple Silicon on macOS 15 or later.

## Why This Comes Before More Features

Lumen already has Finder-like selection, grid/list browsing, Quick Look, favorites, drag-and-drop organization, and inline rename. The most visible remaining gap in that interaction model is trust after a successful cloud mutation: Finder users expect `⌘Z`, but Lumen currently offers no recovery path for rename or move.

Recursive search, drag-out downloads, persistent transfer queues, and OSS version-aware trash remain valuable later work. They require larger data-flow or lifecycle changes and do not belong in the same release as the undo foundation.

## Product Behavior

### Supported undo operations

Lumen keeps one in-memory undo operation for the latest successful action from this list:

- rename one object;
- rename one folder, including every object below that prefix;
- move one or more objects and folders inside the same Bucket.

After one of these succeeds, Lumen exposes both:

- a top feedback capsule with a distinct `撤销` action;
- an Edit-menu command named for the operation, with the standard `⌘Z` shortcut.

The banner action remains visible for 5.5 seconds. The menu command remains available until it is replaced by another successful reversible cloud operation or the application session ends.

### Explicitly unsupported undo operations

Copy, upload, create-folder, and delete do not produce an undo record in 0.0.6. In particular, delete continues to say it cannot be recovered. Lumen must not describe an action as reversible unless it owns a verified inverse operation.

The release provides one undo level, not an undo/redo history stack. Undo state is not persisted across launches.

### Scope and navigation

An undo record is scoped to the exact account ID and Bucket name where it was created. Switching folders inside that Bucket does not discard the record. If another account or Bucket is active, the command is disabled; returning to the original scope makes it available again during the same session.

After a successful undo, Lumen refreshes the current listing and selects restored source items only if they are visible in the current folder. Existing visible-selection rules continue to prevent hidden objects from becoming actionable.

## Safety Model

Each undo record stores the exact object mappings that completed successfully:

```swift
struct CloudUndoOperation: Equatable, Sendable {
    var accountID: UUID
    var bucketName: String
    var title: String
    var mappings: [CloudObjectMapping]
    var favoriteMoves: [CloudFavoriteMove]
    var sourceSelection: Set<String>
    var destinationSelection: Set<String>
}
```

`inverseMappings` swaps every mapping's source and destination. Undo sends those inverse mappings through the existing `OSSClient.performCloudOperation(_:mode:)` path with `.move`. That path checks every restored destination for conflicts before copying and uses `x-oss-forbid-overwrite`, so an external object created at the old name blocks undo instead of being overwritten.

The record is created only after the original operation has fully succeeded. It is removed only after the inverse operation fully succeeds. A failed undo keeps the record available for retry and presents the concrete OSS error.

Folder favorites are recorded as prefix pairs. A successful forward rename or move applies source-to-destination replacement; a successful undo applies the same pairs in reverse. Failed operations do not rewrite favorites.

Only one cloud organization or undo may run at a time through the existing `isOrganizingCloud` gate. Repeated clicks or `⌘Z` presses while work is active do nothing beyond the existing busy feedback.

## Architecture

### Pure undo model

Create `Lumen/OSS/CloudUndoOperation.swift` for `CloudUndoOperation` and `CloudFavoriteMove`. It owns inverse mapping calculation, inverse favorite moves, and restored selection keys. This logic remains independent of SwiftUI and network transport and is covered by pure tests.

### App operation boundary

`AppModel` owns `private(set) var lastCloudUndoOperation: CloudUndoOperation?` and derives:

- `canUndoCloudOperation` from undo presence, scope equality, and busy state;
- `undoCloudOperationTitle` from the record;
- `undoLastCloudOperation() async` for the verified inverse move.

Object rename records one object mapping. Folder rename obtains the exact prefix mappings before executing the forward move instead of using a helper that hides them. General `.move` organization reuses the mappings it already computes. `.copy` does not record undo.

### Command and feedback UI

Extend `BannerMessage` with an optional semantic action enum rather than storing closures:

```swift
enum BannerAction: Equatable {
    case undoCloudOperation
}
```

`BannerView` renders ordinary status content and, when present, a bordered `撤销` button. The button triggers the corresponding `AppModel` method; dismiss remains a separate close interaction so the action cannot be fired accidentally by clicking anywhere in the capsule.

Replace the default Undo/Redo command group with the scoped Lumen undo command. Redo remains unavailable in 0.0.6. The command uses `⌘Z`, follows current focused-window state, and displays the operation-specific title.

Motion uses the existing critically damped `Motion.settle` behavior and respects Reduce Motion. No celebratory animation, floating gradient, or non-native modal is introduced.

## Error Handling

- Destination conflict during undo: show the existing conflict error and keep undo available.
- Missing source after external deletion: show the OSS error and keep undo available.
- Account/Bucket mismatch: disable the command and reject direct method calls without network traffic.
- Incomplete folder listing before forward rename/move: retain the current cancellation behavior and create no undo record.
- Partial source cleanup failure: surface the existing error and create no misleading undo record.
- Refresh failure after a completed inverse move: the cloud undo itself remains complete; clear the record and present refresh state through the existing listing error path.

## Testing Strategy

### Pure model tests

- inverse mappings swap source and destination exactly;
- Unicode and nested object keys remain byte-for-byte equivalent Swift strings;
- favorite prefix pairs reverse correctly;
- restored selection uses original top-level keys.

### App boundary tests

- successful object rename records one undo operation;
- rename conflict records no undo operation;
- successful folder rename records every exact mapping and favorite pair;
- successful multi-item move records its inverse and selection;
- copy records no undo operation;
- wrong-scope undo performs no requests;
- successful undo executes conflict checks, copies destinations, deletes moved sources, refreshes, restores favorites, and clears the record;
- failed undo keeps the record.

### UI and command tests

- actionable banners use the longer display interval;
- banner action routes to undo rather than dismiss;
- `⌘Z` command availability and title derive from the focused model;
- existing Return, Esc, `⌘↓`, double-click, selection, and update tests remain green.

## Release and Compatibility

Advance every project and packaging version to 0.0.6/build 6. Update README shortcuts and organization documentation, add `docs/releases/v0.0.6.md`, regenerate the signed appcast while retaining builds 5 and 4, package and launch-test the DMG, then publish GitHub tag and Latest Release `v0.0.6`.

The app remains non-sandboxed to preserve the established data and Keychain path. Sparkle stays pinned to 2.9.2, and the update feed remains `https://github.com/ihopefulChina/Lumen/releases/latest/download/appcast.xml`.

No application icon bitmap, canvas size, or subject footprint changes in this release.

## Out of Scope

- undo or restore for delete;
- undo for copy, upload, or folder creation;
- redo or multi-level history;
- persisted undo after relaunch;
- cross-Bucket operations;
- recursive/global search;
- drag-out downloads;
- website implementation, which starts only after v0.0.6 is published.

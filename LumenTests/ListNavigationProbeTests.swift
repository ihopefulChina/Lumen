#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import Lumen

@MainActor
@Suite(.serialized)
struct ListNavigationProbeTests {
    @Test func deepNavigationAndBackKeepsResponding() async throws {
        let harness = makeHarness()
        defer { harness.close() }

        // 1. Initial listing for "".
        try await harness.waitForListing(after: nil)
        #expect(harness.model.browser.prefix.isEmpty)
        #expect(harness.rowIndex(for: "a/") == 0)

        // 2. Double-click into "a/", then into "a/a1/", then into "a/a1/deep/".
        try await harness.doubleClickRow(for: "a/")
        #expect(harness.model.browser.prefix == "a/")
        try await harness.doubleClickRow(for: "a/a1/")
        #expect(harness.model.browser.prefix == "a/a1/")
        try await harness.doubleClickRow(for: "a/a1/deep/")
        #expect(harness.model.browser.prefix == "a/a1/deep/")

        // 3. A few extra single clicks on rows.
        try await harness.clickRow(for: "a/a1/deep/item.txt")
        try await harness.clickRow(for: "a/a1/deep/item2.txt")

        // 4. Go back repeatedly, clicking rows along the way.
        var before = harness.model.browser.lastRefresh
        harness.model.goBack()
        try await harness.waitForListing(after: before)
        #expect(harness.model.browser.prefix == "a/a1/")
        try await harness.clickRow(for: "a/a1/item.txt")
        before = harness.model.browser.lastRefresh
        harness.model.goBack()
        try await harness.waitForListing(after: before)
        #expect(harness.model.browser.prefix == "a/")
        try await harness.clickRow(for: "a/file1.txt")
        before = harness.model.browser.lastRefresh
        harness.model.goBack()
        try await harness.waitForListing(after: before)
        #expect(harness.model.browser.prefix.isEmpty)

        // 5. The main thread must still process clicks and selection.
        try await harness.clickRow(for: "a/")
        #expect(harness.model.browser.selectedKeys == ["a/"], "browser stopped responding after back-navigation; selectedKeys=\(harness.model.browser.selectedKeys)")

        // 6. One more round-trip for good measure.
        try await harness.doubleClickRow(for: "b/")
        #expect(harness.model.browser.prefix == "b/")
        before = harness.model.browser.lastRefresh
        harness.model.goBack()
        try await harness.waitForListing(after: before)
        #expect(harness.model.browser.prefix.isEmpty)
        try await harness.clickRow(for: "top.txt")
        #expect(harness.model.browser.selectedKeys == ["top.txt"])
    }

    // MARK: - Fixture

    private func makeHarness() -> Harness {
        setenv("LUMEN_PROBE", "1", 1)
        let account = OSSAccount(
            id: UUID(),
            name: "探针账号",
            accessKeyId: "probe-ak",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let transport = ListingTransport()
        let defaults = UserDefaults(suiteName: "Lumen.NavProbe.\(UUID().uuidString)")!
        let services = AppServices(
            accounts: [account],
            settings: AppSettings(defaults: defaults),
            favorites: FavoriteStore(defaults: defaults)
        )
        let model = AppModel(
            kind: .settings,
            services: services,
            clientProvider: { _, bucket in
                OSSClient(
                    credentials: OSSCredentials(accessKeyId: "probe-ak", accessKeySecret: "probe-sk", securityToken: nil),
                    region: "cn-hangzhou",
                    endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                    bucket: bucket?.name,
                    transport: transport
                )
            }
        )
        model.selectedAccountID = account.id
        model.buckets = [
            OSSBucket(
                name: "probe-bucket",
                regionID: "cn-hangzhou",
                location: "oss-cn-hangzhou",
                extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
                createdAt: nil
            )
        ]
        model.selectedBucketName = "probe-bucket"
        model.browser.viewMode = .list
        model.browser.imagesOnly = false
        let harness = Harness(model: model)
        harness.present()
        return harness
    }

    @MainActor
    final class Harness {
        let model: AppModel
        let window: NSWindow
        private var hosting: NSView?

        init(model: AppModel) {
            self.model = model
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
        }

        func present() {
            let host = NSHostingView(rootView: RootView().environment(model))
            hosting = host
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // The real app calls this from WorkspaceRoot.onAppear.
            model.bootstrap()
        }

        /// Waits until a listing newer than `start` has been applied or an
        /// error surfaced (bounded, so a hang fails the test loudly).
        func waitForListing(after start: Date?) async throws {
            for _ in 0..<120 {
                if model.browser.errorMessage != nil { return }
                if !model.browser.isLoading, model.browser.lastRefresh != start { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            print("PROBE waitForListing timed out: isLoading=\(model.browser.isLoading) lastRefresh=\(String(describing: model.browser.lastRefresh)) start=\(String(describing: start)) prefix=\(model.browser.prefix)")
            throw HarnessError.listingTimedOut
        }

        func close() {
            window.orderOut(nil)
        }

        func rowIndex(for key: String) -> Int {
            let folders = model.browser.visibleFolders
            let objects = model.browser.visibleObjects
            let all = folders.map(\.prefix) + objects.map(\.key)
            return all.firstIndex(of: key) ?? -1
        }

        func clickRow(for key: String) async throws {
            let row = rowIndex(for: key)
            guard row >= 0 else { throw HarnessError.rowNotFound(key) }
            try await settleForTableUpdate()
            try await click(at: try centerOfTableRow(row), count: 1)
        }

        func doubleClickRow(for key: String) async throws {
            let row = rowIndex(for: key)
            guard row >= 0 else { throw HarnessError.rowNotFound(key) }
            try await settleForTableUpdate()
            let point = try centerOfTableRow(row)
            let before = model.browser.lastRefresh
            try await click(at: point, count: 1)
            try await click(at: point, count: 2)
            try await waitForListing(after: before)
        }

        func centerOfTableRow(_ row: Int) throws -> CGPoint {
            guard let table = findTableView(in: window.contentView) else {
                throw HarnessError.tableNotFound
            }
            guard row >= 0, row < table.numberOfRows else {
                throw HarnessError.rowOutOfRange(row)
            }
            table.scrollRowToVisible(row)
            window.layoutIfNeeded()
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else {
                throw HarnessError.rowViewMissing(row)
            }
            let point = NSPoint(x: rowView.bounds.midX, y: rowView.bounds.midY)
            let visible = rowView.visibleRect
            let target = NSPoint(x: min(max(point.x, visible.minX + 4), visible.maxX - 4),
                                 y: min(max(point.y, visible.minY + 2), visible.maxY - 2))
            return rowView.convert(target, to: nil)
        }

        func click(at windowPoint: CGPoint, count: Int) async throws {
            for clickIndex in 1...count {
                guard let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickIndex,
                    pressure: 1
                ) else { throw HarnessError.eventCreationFailed }
                guard let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickIndex,
                    pressure: 0
                ) else { throw HarnessError.eventCreationFailed }
                NSApp.sendEvent(down)
                NSApp.sendEvent(up)
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        /// Lets SwiftUI settle (rows swapped, overlay actions updated) before
        /// the next interaction samples row geometry.
        func settleForTableUpdate() async throws {
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }

        private func findTableView(in root: NSView?) -> NSTableView? {
            guard let root else { return nil }
            var tables: [NSTableView] = []
            collectTables(in: root, into: &tables)
            return tables.max { $0.numberOfColumns < $1.numberOfColumns }
        }

        private func collectTables(in root: NSView?, into result: inout [NSTableView]) {
            guard let root else { return }
            if let table = root as? NSTableView { result.append(table) }
            for child in root.subviews {
                collectTables(in: child, into: &result)
            }
        }
    }

    enum HarnessError: Error {
        case eventCreationFailed
        case tableNotFound
        case rowNotFound(String)
        case rowOutOfRange(Int)
        case rowViewMissing(Int)
        case listingTimedOut
    }
}

private actor ListingTransport: OSSHTTPTransport {
    static let tree: [String: (folders: [String], objects: [String])] = [
        "": (["a/", "b/"], ["top.txt"]),
        "a/": (["a/a1/", "a/a2/"], ["a/file1.txt", "a/file2.txt"]),
        "a/a1/": (["a/a1/deep/"], ["a/a1/item.txt"]),
        "a/a1/deep/": ([], ["a/a1/deep/item.txt", "a/a1/deep/item2.txt"]),
        "a/a2/": ([], ["a/a2/leaf.txt"]),
        "b/": ([], ["b/other.txt"])
    ]

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        try? await Task.sleep(for: .milliseconds(30))
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return OSSHTTPResult(status: 400, headers: [:], data: Data(), temporaryDownloadURL: nil)
        }
        let prefix = components.queryItems?.first(where: { $0.name == "prefix" })?.value ?? ""
        let (folders, objects) = Self.tree[prefix] ?? ([], [])
        var xml = "<ListBucketResult>"
        xml += "<IsTruncated>false</IsTruncated>"
        for folder in folders {
            xml += "<CommonPrefixes><Prefix>\(folder)</Prefix></CommonPrefixes>"
        }
        for object in objects {
            xml += "<Contents><Key>\(object)</Key><Size>10</Size><ETag>\"probe\"</ETag>"
            xml += "<LastModified>2026-08-01T00:00:00.000Z</LastModified><StorageClass>Standard</StorageClass></Contents>"
        }
        xml += "</ListBucketResult>"
        print("PROBE transport responded prefix=\(prefix) folders=\(folders)")
        return OSSHTTPResult(status: 200, headers: [:], data: Data(xml.utf8), temporaryDownloadURL: nil)
    }
}
#endif

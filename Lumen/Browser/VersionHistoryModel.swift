import Foundation
import Observation

@MainActor
@Observable
final class VersionHistoryModel {
    let title: String
    let prefix: String
    let markerOnly: Bool
    var rows: [VersionHistoryRow] = []
    var selection: Set<String> = []
    var isLoading = false
    var isRestoring = false
    var isIncomplete = false
    var errorMessage: String?

    private let client: OSSClient
    private let onRecovered: @MainActor () -> Void
    private var generation = 0

    init(
        title: String,
        prefix: String,
        markerOnly: Bool,
        client: OSSClient,
        onRecovered: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.prefix = prefix
        self.markerOnly = markerOnly
        self.client = client
        self.onRecovered = onRecovered
    }

    var selectedRow: VersionHistoryRow? {
        guard let id = selection.first else { return nil }
        return rows.first(where: { $0.id == id })
    }

    func load() async {
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        do {
            let listing = try await client.listAllVersions(prefix: prefix)
            guard request == generation else { return }
            let allRows = VersionHistoryRow.rows(
                versions: markerOnly ? [] : listing.versions,
                deleteMarkers: listing.deleteMarkers
            )
            rows = prefix.isEmpty ? allRows : allRows.filter { $0.key == prefix }
            isIncomplete = listing.incomplete
        } catch is CancellationError {
            return
        } catch {
            guard request == generation else { return }
            errorMessage = error.localizedDescription
        }
        if request == generation { isLoading = false }
    }

    func restore(_ row: VersionHistoryRow) async {
        guard !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        do {
            switch row.kind {
            case .version:
                try await client.restoreVersion(key: row.key, versionID: row.versionID)
            case .deleteMarker:
                _ = try await client.deleteObject(key: row.key, versionID: row.versionID)
            }
            onRecovered()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        isRestoring = false
    }
}

import Foundation
import Observation

struct FavoriteLocation: Codable, Hashable, Identifiable, Sendable {
    var accountID: UUID
    var bucketName: String
    var prefix: String
    var name: String

    var id: String {
        "\(accountID.uuidString)/\(bucketName)/\(prefix)"
    }
}

@MainActor
@Observable
final class FavoriteStore {
    private(set) var items: [FavoriteLocation]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.locations),
           let decoded = try? JSONDecoder().decode([FavoriteLocation].self, from: data) {
            self.items = decoded.uniqued(on: \FavoriteLocation.id)
        } else {
            self.items = []
        }
    }

    func contains(accountID: UUID, bucketName: String, prefix: String) -> Bool {
        items.contains { location in
            location.accountID == accountID
                && location.bucketName == bucketName
                && location.prefix == prefix
        }
    }

    func add(_ location: FavoriteLocation) {
        guard !items.contains(where: { $0.id == location.id }) else { return }
        items.append(location)
        save()
    }

    func remove(_ location: FavoriteLocation) {
        items.removeAll { $0.id == location.id }
        save()
    }

    func remove(accountID: UUID, bucketName: String, prefix: String) {
        items.removeAll { location in
            location.accountID == accountID
                && location.bucketName == bucketName
                && location.prefix == prefix
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Keys.locations)
    }

    private enum Keys {
        static let locations = "browser.favoriteLocations"
    }
}

private extension Array {
    func uniqued<ID: Hashable>(on keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

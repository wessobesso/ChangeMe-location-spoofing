//
//  LocationStore.swift
//  ChangeMe
//

import Foundation

@MainActor
final class LocationStore {
    private let defaults: UserDefaults
    private let recentKey = "changeme.recentLocations.v2"
    private let favoritesKey = "changeme.favoriteLocations.v2"
    private let legacyRecentKey = "changeme.recentLocations"
    private let legacyFavoritesKey = "changeme.favoriteLocations"
    private let migrationFlagKey = "changeme.locationStore.migratedToV2"
    private let maxRecent = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    func loadRecent() -> [MapLocation] {
        decode(key: recentKey).filter(\.isSchemaCompatible)
    }

    func loadFavorites() -> [MapLocation] {
        decode(key: favoritesKey).filter(\.isSchemaCompatible)
    }

    func addRecent(_ location: MapLocation) {
        guard location.isSchemaCompatible else { return }
        var items = loadRecent().filter {
            !CoordinateValidation.approximatelyEqual($0.coordinate, location.coordinate)
        }
        var stored = location
        stored.timestamp = .now
        stored.schemaVersion = MapLocation.currentSchemaVersion
        items.insert(stored, at: 0)
        if items.count > maxRecent {
            items = Array(items.prefix(maxRecent))
        }
        encode(items, key: recentKey)
    }

    func clearRecent() {
        defaults.removeObject(forKey: recentKey)
    }

    func addFavorite(_ location: MapLocation) {
        guard location.isSchemaCompatible else { return }
        var items = loadFavorites()
        if items.contains(where: {
            CoordinateValidation.approximatelyEqual($0.coordinate, location.coordinate)
        }) {
            return
        }
        var stored = location
        stored.timestamp = .now
        stored.schemaVersion = MapLocation.currentSchemaVersion
        items.insert(stored, at: 0)
        encode(items, key: favoritesKey)
    }

    func removeFavorite(_ location: MapLocation) {
        let items = loadFavorites().filter { $0.id != location.id }
        encode(items, key: favoritesKey)
    }

    func isFavorite(_ location: MapLocation) -> Bool {
        loadFavorites().contains {
            CoordinateValidation.approximatelyEqual($0.coordinate, location.coordinate)
        }
    }

    private func migrateIfNeeded() {
        guard defaults.bool(forKey: migrationFlagKey) == false else { return }

        // Drop potentially corrupted v1 records (name/coordinate mismatches like “Apple Park” with wrong lat/lon).
        defaults.removeObject(forKey: legacyRecentKey)
        defaults.removeObject(forKey: legacyFavoritesKey)
        defaults.set(true, forKey: migrationFlagKey)
    }

    private func decode(key: String) -> [MapLocation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MapLocation].self, from: data)) ?? []
    }

    private func encode(_ items: [MapLocation], key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}

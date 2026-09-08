//
//  MapLocation.swift
//  ChangeMe
//

import CoreLocation
import Foundation

struct MapLocation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Primary display title (place name or short address). Always stored with this record's coordinates.
    var name: String?
    /// Secondary line (locality / full address). Always stored with this record's coordinates.
    var subtitle: String?
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    /// Schema version for UserDefaults migration.
    var schemaVersion: Int

    static let currentSchemaVersion = 2

    init(
        id: UUID = UUID(),
        name: String? = nil,
        subtitle: String? = nil,
        latitude: Double,
        longitude: Double,
        timestamp: Date = .now,
        schemaVersion: Int = MapLocation.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
    }

    init(
        id: UUID = UUID(),
        name: String? = nil,
        subtitle: String? = nil,
        coordinate: CLLocationCoordinate2D,
        timestamp: Date = .now
    ) {
        self.init(
            id: id,
            name: name,
            subtitle: subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timestamp: timestamp
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let subtitle, !subtitle.isEmpty { return subtitle.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? subtitle }
        return coordinateString
    }

    /// Compact secondary line for lists (city / region), avoiding full postal dumps when possible.
    var secondaryLine: String {
        guard let subtitle, !subtitle.isEmpty else { return coordinateString }
        let parts = subtitle
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let name, !name.isEmpty, parts.first?.caseInsensitiveCompare(name) == .orderedSame {
            let rest = parts.dropFirst()
            if rest.isEmpty { return coordinateString }
            // Prefer "City, ON" style (skip postal-heavy tails when long).
            return Array(rest.prefix(2)).joined(separator: ", ")
        }

        if parts.count >= 2 {
            return Array(parts.suffix(min(2, parts.count))).joined(separator: ", ")
        }
        return subtitle == name ? coordinateString : subtitle
    }

    /// Multi-line address for the sidebar, deduplicating identical name/address lines.
    var formattedAddressLines: [String] {
        var lines: [String] = []
        if let name, !name.isEmpty {
            lines.append(name)
        }

        guard let subtitle, !subtitle.isEmpty else { return lines }

        let parts = subtitle
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for part in parts {
            if lines.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                continue
            }
            lines.append(part)
        }
        return lines
    }

    var coordinateString: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    var isSchemaCompatible: Bool {
        schemaVersion >= 2 && name != nil
    }

    /// Fallback world view when Mac location is unavailable.
    static let worldFallback = MapLocation(
        name: "World",
        subtitle: nil,
        latitude: 20,
        longitude: 0
    )
}

enum CoordinateValidation {
    static func isValidLatitude(_ value: Double) -> Bool {
        (-90...90).contains(value)
    }

    static func isValidLongitude(_ value: Double) -> Bool {
        (-180...180).contains(value)
    }

    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate)
            && isValidLatitude(coordinate.latitude)
            && isValidLongitude(coordinate.longitude)
    }

    static func approximatelyEqual(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        tolerance: Double = 0.00015
    ) -> Bool {
        abs(a.latitude - b.latitude) < tolerance
            && abs(a.longitude - b.longitude) < tolerance
    }
}

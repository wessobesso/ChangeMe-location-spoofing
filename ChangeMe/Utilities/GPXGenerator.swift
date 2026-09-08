//
//  GPXGenerator.swift
//  ChangeMe
//

import Foundation

enum GPXGenerator {
    private static let filePrefix = "ChangeMe-waypoint-"

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeMeGPX", isDirectory: true)
    }

    /// Generates a temporary GPX waypoint file with safely escaped XML.
    @discardableResult
    static func generateWaypoint(
        latitude: Double,
        longitude: Double,
        name: String = "Simulated Location"
    ) throws -> URL {
        guard CoordinateValidation.isValidLatitude(latitude),
              CoordinateValidation.isValidLongitude(longitude)
        else {
            throw AppError.invalidCoordinates
        }

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppError.gpxCreationFailed(error.localizedDescription)
        }

        let lat = String(format: "%.8f", latitude)
        let lon = String(format: "%.8f", longitude)
        let safeName = xmlEscape(name)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="ChangeMe" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="\(lat)" lon="\(lon)">
                <name>\(safeName)</name>
            </wpt>
        </gpx>
        """

        let filename = "\(filePrefix)\(UUID().uuidString).gpx"
        let url = temporaryDirectory.appendingPathComponent(filename)

        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            throw AppError.gpxCreationFailed(error.localizedDescription)
        }
    }

    static func cleanupTemporaryFiles() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents where url.pathExtension.lowercased() == "gpx" {
            try? fm.removeItem(at: url)
        }
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

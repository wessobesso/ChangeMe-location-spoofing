//
//  LocationSessionControl.swift
//  Shared between ChangeMe (Mac) and ChangeMeDeviceUITests.
//

import Foundation

/// File-based control channel for a supported XCUITest location session.
/// Mac app writes commands; UI tests apply them via XCUIDevice.location.
enum LocationSessionControl {
    static let directoryName = "ChangeMe"
    static let commandFileName = "LocationSessionControl.json"
    static let statusFileName = "LocationSessionStatus.json"

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var commandURL: URL { directoryURL.appendingPathComponent(commandFileName) }
    static var statusURL: URL { directoryURL.appendingPathComponent(statusFileName) }

    enum Action: String, Codable {
        case set
        case clear
    }

    struct Command: Codable, Equatable {
        var action: Action
        var latitude: Double?
        var longitude: Double?
        var previousLatitude: Double?
        var previousLongitude: Double?
        var updatedAt: Date

        static func set(latitude: Double, longitude: Double) -> Command {
            Command(
                action: .set,
                latitude: latitude,
                longitude: longitude,
                previousLatitude: nil,
                previousLongitude: nil,
                updatedAt: .now
            )
        }

        static func clear(previousLatitude: Double? = nil, previousLongitude: Double? = nil) -> Command {
            Command(
                action: .clear,
                latitude: nil,
                longitude: nil,
                previousLatitude: previousLatitude,
                previousLongitude: previousLongitude,
                updatedAt: .now
            )
        }
    }

    struct Status: Codable, Equatable {
        var state: String
        var latitude: Double?
        var longitude: Double?
        var message: String?
        var updatedAt: Date
    }

    /// Host-side persistence experiment log (Mac only; not read by on-device tests).
    static let persistenceFileName = "LocationPersistenceDiagnostics.json"
    static var persistenceURL: URL { directoryURL.appendingPathComponent(persistenceFileName) }

    struct PersistenceDiagnostics: Codable, Equatable {
        var requestedLatitude: Double
        var requestedLongitude: Double
        var verifiedLatitude: Double?
        var verifiedLongitude: Double?
        var assignmentTimestamp: String?
        var verificationTimestamp: String?
        var testMethodEndTimestamp: String?
        var xcodebuildExitTimestamp: String
        var executedLocationNil: Bool
        var additionalTestsAfterward: Bool
        var note: String
    }

    static func writePersistenceDiagnostics(_ diagnostics: PersistenceDiagnostics) throws {
        try ensureDirectory()
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(diagnostics)
        try data.write(to: persistenceURL, options: .atomic)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func writeCommand(_ command: Command) throws {
        try ensureDirectory()
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(command)
        try data.write(to: commandURL, options: .atomic)
    }

    static func readCommand() -> Command? {
        guard let data = try? Data(contentsOf: commandURL) else { return nil }
        return try? JSONDecoder.iso8601.decode(Command.self, from: data)
    }

    static func writeStatus(_ status: Status) throws {
        try ensureDirectory()
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(status)
        try data.write(to: statusURL, options: .atomic)
    }

    static func readStatus() -> Status? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder.iso8601.decode(Status.self, from: data)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

//
//  LocationSessionProtocol.swift
//  ChangeMe
//
//  Line-delimited JSON protocol between ChangeMe (Mac) and the physical UITest runner.
//

import Foundation

enum LocationSessionMessage {
    static let protocolVersion = 1

    struct Envelope: Codable, Equatable, Sendable {
        var type: String
        var token: String?
        var id: String?
        var latitude: Double?
        var longitude: Double?
        var message: String?
        var elapsedSeconds: Double?
        var version: Int?
        /// Companion Core Location horizontalAccuracy (meters), when sampled.
        var horizontalAccuracy: Double?

        static func hello(token: String) -> Envelope {
            Envelope(type: "HELLO", token: token, version: protocolVersion)
        }

        static func ready(latitude: Double, longitude: Double) -> Envelope {
            Envelope(type: "READY", latitude: latitude, longitude: longitude)
        }

        static func set(id: String, latitude: Double, longitude: Double, token: String) -> Envelope {
            Envelope(type: "SET", token: token, id: id, latitude: latitude, longitude: longitude)
        }

        static func applied(id: String?, latitude: Double, longitude: Double) -> Envelope {
            Envelope(type: "APPLIED", id: id, latitude: latitude, longitude: longitude)
        }

        static func stop(token: String) -> Envelope {
            Envelope(type: "STOP", token: token)
        }

        static func stopped() -> Envelope {
            Envelope(type: "STOPPED")
        }

        static func ping(token: String) -> Envelope {
            Envelope(type: "PING", token: token)
        }

        static func pong() -> Envelope {
            Envelope(type: "PONG")
        }

        static func alive(elapsedSeconds: Double, latitude: Double?, longitude: Double?) -> Envelope {
            Envelope(
                type: "ALIVE",
                latitude: latitude,
                longitude: longitude,
                elapsedSeconds: elapsedSeconds
            )
        }

        /// Mac asks UITest to read ChangeMeDevice Core Location without reassigning XCUIDevice.location.
        static func sample(token: String, id: String) -> Envelope {
            Envelope(type: "SAMPLE", token: token, id: id)
        }

        static func sampleResult(
            id: String?,
            latitude: Double?,
            longitude: Double?,
            horizontalAccuracy: Double?,
            elapsedSeconds: Double?,
            message: String? = nil
        ) -> Envelope {
            Envelope(
                type: "SAMPLE_RESULT",
                id: id,
                latitude: latitude,
                longitude: longitude,
                message: message,
                elapsedSeconds: elapsedSeconds,
                horizontalAccuracy: horizontalAccuracy
            )
        }

        static func error(_ message: String) -> Envelope {
            Envelope(type: "ERROR", message: message)
        }
    }

    static func encode(_ envelope: Envelope) throws -> Data {
        var data = try JSONEncoder().encode(envelope)
        data.append(contentsOf: [0x0A])
        return data
    }

    static func decodeLine(_ line: String) -> Envelope? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}

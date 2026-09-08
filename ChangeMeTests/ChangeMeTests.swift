//
//  ChangeMeTests.swift
//  ChangeMeTests
//

import CoreLocation
import Testing
@testable import ChangeMe

struct ChangeMeTests {
    @Test func gpxGeneratorCreatesValidWaypointFile() throws {
        let url = try GPXGenerator.generateWaypoint(
            latitude: 43.6532,
            longitude: -79.3832,
            name: "Toronto"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let xml = try String(contentsOf: url, encoding: .utf8)
        #expect(xml.contains("lat=\"43.65320000\""))
        #expect(xml.contains("lon=\"-79.38320000\""))
        #expect(xml.contains("<name>Toronto</name>"))
        #expect(xml.contains("<gpx"))
    }

    @Test func gpxGeneratorEscapesUnsafeName() throws {
        let url = try GPXGenerator.generateWaypoint(
            latitude: 0,
            longitude: 0,
            name: "A & B <C>"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let xml = try String(contentsOf: url, encoding: .utf8)
        #expect(xml.contains("A &amp; B &lt;C&gt;"))
        #expect(!xml.contains("A & B <C>"))
    }

    @Test func coordinateValidationRejectsOutOfRange() {
        #expect(CoordinateValidation.isValidLatitude(91) == false)
        #expect(CoordinateValidation.isValidLongitude(-181) == false)
        #expect(
            CoordinateValidation.isValid(
                CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
            )
        )
    }

    @Test func simulationStateTitles() {
        #expect(SimulationState.idle.title == "No simulation")
        #expect(SimulationState.preparing.title == "Starting Simulation…")
        #expect(SimulationState.active.title == "Simulation Active")
        #expect(SimulationState.stopping.title == "Stopping…")
        #expect(SimulationState.failed("x").title == "Simulation Failed")
        #expect(SimulationState.idle.canTransition(to: .preparing))
        #expect(!SimulationState.idle.canTransition(to: .active))
        #expect(!SimulationState.stopping.canTransition(to: .updating))
    }
}

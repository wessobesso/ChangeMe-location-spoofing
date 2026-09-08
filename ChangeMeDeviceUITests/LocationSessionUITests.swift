//
//  LocationSessionUITests.swift
//  ChangeMeDeviceUITests
//
//  Public API (Xcode 26.6 / XCUIAutomation):
//    XCUIDevice.shared.location = XCUILocation(location: CLLocation(...))
//    XCUIDevice.shared.location = nil
//
//  Production automation uses SEPARATE tests for set and clear.
//  Start must NEVER clear. Stop is the only path that sets location = nil.
//

import CoreLocation
import XCTest

final class LocationSessionUITests: XCTestCase {
    private let coordinateTolerance = 0.01

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Default XCTest executionTimeAllowance is 600s and only enforced when
        // -test-timeouts-enabled YES. Raise allowance so long sessions are safe if enabled.
        executionTimeAllowance = 60 * 60 * 6 // 6 hours (rounded up to nearest minute)
    }

    // Intentionally NO tearDown / tearDownWithError that clears location.
    // Persistence experiments require the simulated location to survive test exit.

    // MARK: - Phase 1: hold session alive (no network, no clear)

    /// Keeps XCUIDevice.location set for 5 minutes without reassignment or clear.
    func testHoldChangeMeLocationFiveMinutes() throws {
        let latitude = 43.6426
        let longitude = -79.3871
        try injectAndAssert(latitude: latitude, longitude: longitude, name: "CN Tower hold")

        let holdSeconds: TimeInterval = 5 * 60
        let started = Date()
        var tick = 0
        while Date().timeIntervalSince(started) < holdSeconds {
            let inverted = XCTestExpectation(description: "hold-slice-\(tick)")
            inverted.isInverted = true
            XCTWaiter().wait(for: [inverted], timeout: 30)

            tick += 1
            let elapsed = Date().timeIntervalSince(started)
            let app = XCUIApplication()
            let coords = readCoordinatesIfPresent(in: app)
            let stillMatch: Bool = {
                guard let coords else { return false }
                return abs(coords.0 - latitude) < coordinateTolerance
                    && abs(coords.1 - longitude) < coordinateTolerance
            }()
            print(
                "ChangeMeDIAG session_alive elapsed=\(Int(elapsed))s requested=\(latitude),\(longitude) companionMatch=\(stillMatch) coords=\(String(describing: coords))"
            )
        }

        let finalApp = XCUIApplication()
        let appForFinal = (finalApp.state == .runningForeground) ? finalApp : launchCompanion()
        let finalCoords = waitForCoordinates(in: appForFinal, timeout: 30, matching: (latitude, longitude))
        XCTAssertNotNil(finalCoords, "After 5-minute hold, companion no longer reports CN Tower")
        print("ChangeMeDIAG hold_complete verified=\(String(describing: finalCoords)) cleared=false")
    }

    // MARK: - Production long-lived session (Mac TCP control channel)

    /// Long-lived session: connect to ChangeMe Mac server, apply SET commands until STOP.
    func testRunChangeMeLocationSession() throws {
        let env = ProcessInfo.processInfo.environment
        func envValue(_ keys: [String]) -> String? {
            for key in keys where env[key]?.isEmpty == false { return env[key] }
            return nil
        }

        guard let portText = envValue(["TEST_RUNNER_CHANGEME_PORT", "CHANGEME_PORT"]),
              let port = UInt16(portText),
              let token = envValue(["TEST_RUNNER_CHANGEME_TOKEN", "CHANGEME_TOKEN"])
        else {
            XCTFail("Missing CHANGEME_PORT/TOKEN for long-lived session")
            return
        }

        let initialLat = envValue(["TEST_RUNNER_CHANGEME_LATITUDE", "CHANGEME_LATITUDE"]).flatMap(Double.init) ?? 43.6426
        let initialLon = envValue(["TEST_RUNNER_CHANGEME_LONGITUDE", "CHANGEME_LONGITUDE"]).flatMap(Double.init) ?? -79.3871

        addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            let buttons = ["Allow", "OK", "Allow While Using App"]
            for title in buttons {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        let listener = LocationSessionListener(port: port, token: token)
        do {
            try listener.start(timeout: 15)
        } catch {
            XCTFail("Failed to start device listener on \(port): \(error.localizedDescription)")
            return
        }

        // Wait for Mac to connect (inbound over USB link-local).
        XCTAssertTrue(listener.waitForClient(timeout: 90), "Mac did not connect to UITest listener on port \(port)")

        // Optional HELLO from Mac with token.
        if let hello = listener.waitForMessage(types: ["HELLO"], timeout: 15) {
            print("ChangeMeDIAG hello_from_mac token_ok=\(hello.token == token)")
        }
        print("ChangeMeDIAG session_connected port=\(port)")

        // Initial injection (do not reassign unless SET arrives).
        applyLocation(latitude: initialLat, longitude: initialLon)
        let app = launchCompanion()
        let verified = waitForCoordinates(in: app, timeout: 45, matching: (initialLat, initialLon))
        guard let verified else {
            try? listener.send(.error("Companion did not verify initial coordinate"))
            XCTFail("Companion did not verify initial coordinate")
            listener.cancel()
            return
        }
        print("ChangeMeDevice verified session start: \(verified.0), \(verified.1)")
        try listener.send(.ready(latitude: verified.0, longitude: verified.1))
        // Do not also send APPLIED here — READY is the start ack; APPLIED is for SET updates.

        var current = verified
        let sessionStarted = Date()
        var stopRequested = false

        while !stopRequested {
            // Include SAMPLE so Mac can poll companion Core Location without reassignment.
            if let message = listener.waitForMessage(types: ["SET", "STOP", "PING", "SAMPLE"], timeout: 30) {
                switch message.type {
                case "SET":
                    guard let lat = message.latitude, let lon = message.longitude else {
                        try? listener.send(.error("SET missing coordinates"))
                        continue
                    }
                    if abs(lat - current.0) > 0.000_001 || abs(lon - current.1) > 0.000_001 {
                        applyLocation(latitude: lat, longitude: lon)
                        let running = XCUIApplication()
                        if running.state != .runningForeground {
                            _ = launchCompanion()
                        }
                        if let match = waitForCoordinates(
                            in: XCUIApplication(),
                            timeout: 30,
                            matching: (lat, lon)
                        ) {
                            current = match
                        } else {
                            current = (lat, lon)
                        }
                    }
                    try listener.send(.applied(id: message.id, latitude: current.0, longitude: current.1))
                    print("ChangeMeDevice verified session update: \(current.0), \(current.1)")

                case "STOP":
                    stopRequested = true

                case "PING":
                    try? listener.send(.pong())

                case "SAMPLE":
                    // Evidence-only: read ChangeMeDevice Core Location. Do NOT reassign XCUIDevice.location.
                    let elapsed = Date().timeIntervalSince(sessionStarted)
                    let running = XCUIApplication()
                    let app = (running.state == .runningForeground) ? running : launchCompanion()
                    let live = readCoordinatesIfPresent(in: app)
                    let accuracy = readHorizontalAccuracyIfPresent(in: app)
                    try? listener.send(
                        .sampleResult(
                            id: message.id,
                            latitude: live?.0,
                            longitude: live?.1,
                            horizontalAccuracy: accuracy,
                            elapsedSeconds: elapsed,
                            message: live == nil ? "companion_coords_unavailable" : nil
                        )
                    )
                    print(
                        "ChangeMeDIAG sample_result elapsed=\(Int(elapsed))s live=\(String(describing: live)) accuracy=\(String(describing: accuracy)) appliedProxy=\(current.0),\(current.1)"
                    )

                default:
                    break
                }
            } else {
                let elapsed = Date().timeIntervalSince(sessionStarted)
                try? listener.send(.alive(elapsedSeconds: elapsed, latitude: current.0, longitude: current.1))
                print("ChangeMeDIAG session_alive elapsed=\(Int(elapsed))s requested=\(current.0),\(current.1)")
            }
        }

        print("ChangeMeDIAG T0_clear_assignment=\(iso8601Now())")
        XCUIDevice.shared.location = nil
        let clearApp = launchCompanion()
        let after = waitForCoordinates(in: clearApp, timeout: 45)
        print("ChangeMeDevice after clear: \(String(describing: after))")
        try? listener.send(.stopped())
        listener.cancel()
        print("ChangeMeDIAG session_stopped=\(iso8601Now())")
    }

    // MARK: - Production one-shot START (set only)

    /// ChangeMe macOS Start Simulation / Persistence Test entry point.
    /// Sets XCUIDevice.location, verifies companion, and does NOT clear.
    func testSetChangeMeLocation() throws {
        let (lat, lon, name) = try resolveSetCoordinates()
        try injectAndAssert(latitude: lat, longitude: lon, name: name)
        try? LocationSessionControl.writeStatus(
            .init(
                state: "injected",
                latitude: lat,
                longitude: lon,
                message: "Set-only via XCUIDevice.location (no clear)",
                updatedAt: .now
            )
        )
        print("ChangeMeDIAG T2_method_complete=\(iso8601Now()) cleared=false")
    }

    // MARK: - Production STOP (clear only)

    /// ChangeMe macOS Stop Simulation entry point.
    /// This is the ONLY production automation path that executes location = nil.
    func testClearChangeMeLocation() throws {
        try performClear()
    }

    private func performClear() throws {
        let previous = resolvePreviousCoordinate()
        print("ChangeMeDIAG T0_clear_assignment=\(iso8601Now())")
        XCUIDevice.shared.location = nil
        let app = launchCompanion()
        let coords = waitForCoordinates(in: app, timeout: 45)
        XCTAssertNotNil(coords, "Companion did not show coordinates after clear")

        if let previous, let (lat, lon) = coords {
            let stillPrevious =
                abs(lat - previous.0) < coordinateTolerance
                && abs(lon - previous.1) < coordinateTolerance
            XCTAssertFalse(
                stillPrevious,
                "After clear, companion still reports previous simulated coordinate \(lat), \(lon)"
            )
            print("ChangeMeDevice after clear: \(lat), \(lon) leftPrevious=\(!stillPrevious)")
        } else if let (lat, lon) = coords {
            print("ChangeMeDevice after clear: \(lat), \(lon)")
        }

        try? LocationSessionControl.writeStatus(
            .init(
                state: "cleared",
                latitude: coords?.0,
                longitude: coords?.1,
                message: "Cleared via XCUIDevice.location = nil",
                updatedAt: .now
            )
        )
        print("ChangeMeDIAG T2_clear_method_complete=\(iso8601Now())")
    }

    // MARK: - Legacy combined entry (kept for older scripts; prefer set/clear tests)

    func testApplyChangeMeLocationCommand() throws {
        let command = try resolveCommand()
        switch command.action {
        case .set:
            guard let lat = command.latitude, let lon = command.longitude else {
                XCTFail("set command missing latitude/longitude")
                return
            }
            try injectAndAssert(latitude: lat, longitude: lon, name: "ChangeMe command")
            print("ChangeMeDIAG T2_method_complete=\(iso8601Now()) cleared=false")
        case .clear:
            try performClear()
        }
    }

    // MARK: - Development / verification tests

    func testClearSimulatedLocationReturnsNonCNTower() throws {
        XCUIDevice.shared.location = nil
        let app = launchCompanion()
        let coords = waitForCoordinates(in: app, timeout: 45)
        XCTAssertNotNil(coords, "Companion did not show coordinates after clear")
        if let (lat, lon) = coords {
            let stillCNTower = abs(lat - 43.6426) < 0.01 && abs(lon - (-79.3871)) < 0.01
            print("ChangeMeDevice after clear: \(lat), \(lon) stillCNTower=\(stillCNTower)")
        }
    }

    func testInjectCNTower() throws {
        try injectAndAssert(latitude: 43.6426, longitude: -79.3871, name: "CN Tower")
    }

    func testInjectTimesSquare() throws {
        try injectAndAssert(latitude: 40.7580, longitude: -73.9855, name: "Times Square")
    }

    func testInjectFromEnvironment() throws {
        let (lat, lon, name) = try resolveSetCoordinates()
        try injectAndAssert(latitude: lat, longitude: lon, name: name)
    }

    // MARK: - Resolve parameters

    private func resolveSetCoordinates() throws -> (Double, Double, String) {
        let env = ProcessInfo.processInfo.environment
        func envValue(_ keys: [String]) -> String? {
            for key in keys {
                if let value = env[key], !value.isEmpty { return value }
            }
            return nil
        }

        let lat = envValue(["TEST_RUNNER_CHANGEME_LATITUDE", "CHANGEME_LATITUDE"]).flatMap(Double.init)
            ?? LocationSessionControl.readCommand()?.latitude
        let lon = envValue(["TEST_RUNNER_CHANGEME_LONGITUDE", "CHANGEME_LONGITUDE"]).flatMap(Double.init)
            ?? LocationSessionControl.readCommand()?.longitude

        guard let lat, let lon else {
            XCTFail(
                "No coordinates. Set TEST_RUNNER_CHANGEME_LATITUDE/LONGITUDE or write \(LocationSessionControl.commandURL.path)"
            )
            throw CancellationError()
        }
        return (lat, lon, "ChangeMe set")
    }

    private func resolvePreviousCoordinate() -> (Double, Double)? {
        let env = ProcessInfo.processInfo.environment
        func envValue(_ keys: [String]) -> String? {
            for key in keys {
                if let value = env[key], !value.isEmpty { return value }
            }
            return nil
        }
        if let lat = envValue(["TEST_RUNNER_CHANGEME_PREV_LATITUDE", "CHANGEME_PREV_LATITUDE"]).flatMap(Double.init),
           let lon = envValue(["TEST_RUNNER_CHANGEME_PREV_LONGITUDE", "CHANGEME_PREV_LONGITUDE"]).flatMap(Double.init) {
            return (lat, lon)
        }
        if let command = LocationSessionControl.readCommand(),
           let lat = command.previousLatitude,
           let lon = command.previousLongitude {
            return (lat, lon)
        }
        if let status = LocationSessionControl.readStatus(),
           (status.state == "active" || status.state == "injected"),
           let lat = status.latitude,
           let lon = status.longitude {
            return (lat, lon)
        }
        return nil
    }

    private func resolveCommand() throws -> LocationSessionControl.Command {
        let env = ProcessInfo.processInfo.environment
        func envValue(_ keys: [String]) -> String? {
            for key in keys {
                if let value = env[key], !value.isEmpty { return value }
            }
            return nil
        }

        if let actionText = envValue(["TEST_RUNNER_CHANGEME_ACTION", "CHANGEME_ACTION"]) {
            let action: LocationSessionControl.Action
            switch actionText.lowercased() {
            case "set":
                action = .set
            case "clear":
                action = .clear
            default:
                XCTFail("Unknown CHANGEME_ACTION: \(actionText)")
                throw CancellationError()
            }

            let lat = envValue(["TEST_RUNNER_CHANGEME_LATITUDE", "CHANGEME_LATITUDE"]).flatMap(Double.init)
            let lon = envValue(["TEST_RUNNER_CHANGEME_LONGITUDE", "CHANGEME_LONGITUDE"]).flatMap(Double.init)
            let prevLat = envValue(["TEST_RUNNER_CHANGEME_PREV_LATITUDE", "CHANGEME_PREV_LATITUDE"]).flatMap(Double.init)
            let prevLon = envValue(["TEST_RUNNER_CHANGEME_PREV_LONGITUDE", "CHANGEME_PREV_LONGITUDE"]).flatMap(Double.init)

            return LocationSessionControl.Command(
                action: action,
                latitude: lat,
                longitude: lon,
                previousLatitude: prevLat,
                previousLongitude: prevLon,
                updatedAt: .now
            )
        }

        if let command = LocationSessionControl.readCommand() {
            return command
        }

        XCTFail(
            "No ChangeMe command. Set TEST_RUNNER_CHANGEME_ACTION (+ lat/lon for set) or write \(LocationSessionControl.commandURL.path)"
        )
        throw CancellationError()
    }

    // MARK: - Helpers

    private func applyLocation(latitude: Double, longitude: Double) {
        print("ChangeMeDIAG T0_assignment=\(iso8601Now()) requested=\(latitude),\(longitude)")
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(latitude: latitude, longitude: longitude)
        )
    }

    private func readCoordinatesIfPresent(in app: XCUIApplication) -> (Double, Double)? {
        let latLabel = app.staticTexts["latitude"]
        guard latLabel.exists else { return nil }
        let latValue = (latLabel.value as? String) ?? latLabel.label
        let lonValue = (app.staticTexts["longitude"].value as? String) ?? app.staticTexts["longitude"].label
        guard let lat = Double(latValue), let lon = Double(lonValue) else { return nil }
        return (lat, lon)
    }

    /// Parses companion accuracy label like "42 m".
    private func readHorizontalAccuracyIfPresent(in app: XCUIApplication) -> Double? {
        let label = app.staticTexts["accuracy"]
        guard label.exists else { return nil }
        let raw = ((label.value as? String) ?? label.label)
            .replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(raw)
    }

    private func injectAndAssert(latitude: Double, longitude: Double, name: String) throws {
        applyLocation(latitude: latitude, longitude: longitude)

        let app = launchCompanion()
        let coords = waitForCoordinates(
            in: app,
            timeout: 45,
            matching: (latitude, longitude)
        )

        guard let (lat, lon) = coords else {
            XCTFail("ChangeMeDevice did not report \(name) (\(latitude), \(longitude))")
            return
        }

        XCTAssertEqual(lat, latitude, accuracy: coordinateTolerance, "Latitude mismatch for \(name)")
        XCTAssertEqual(lon, longitude, accuracy: coordinateTolerance, "Longitude mismatch for \(name)")

        let t1 = iso8601Now()
        print("ChangeMeDIAG T1_verified=\(t1) verified=\(lat),\(lon)")
        print("ChangeMeDevice verified \(name): \(lat), \(lon)")
    }

    private func launchCompanion() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        dismissLocationAlertIfNeeded(in: app)
        return app
    }

    private func waitForCoordinates(
        in app: XCUIApplication,
        timeout: TimeInterval,
        matching expected: (Double, Double)? = nil
    ) -> (Double, Double)? {
        let latLabel = app.staticTexts["latitude"]
        guard latLabel.waitForExistence(timeout: timeout) else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let latText = latLabel.label
            let lonText = app.staticTexts["longitude"].label
            let latValue = latLabel.value as? String ?? latText
            let lonValue = (app.staticTexts["longitude"].value as? String) ?? lonText

            if let lat = Double(latValue), let lon = Double(lonValue) {
                if let expected {
                    if abs(lat - expected.0) < coordinateTolerance,
                       abs(lon - expected.1) < coordinateTolerance {
                        return (lat, lon)
                    }
                } else if latText != "—" && lonText != "—" {
                    return (lat, lon)
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return nil
    }

    private func dismissLocationAlertIfNeeded(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [
            springboard.buttons["Allow While Using App"],
            springboard.buttons["Allow Once"],
            app.alerts.buttons["Allow While Using App"],
            app.alerts.buttons["Allow Once"]
        ]
        for button in candidates {
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

//
//  PhysicalDeviceLocationRunner.swift
//  ChangeMe
//
//  Runs a SINGLE ChangeMeDevice UITest via xcodebuild using public
//  XCUIDevice.location / XCUILocation.
//
//  START → testSetChangeMeLocation (never clears)
//  STOP  → testClearChangeMeLocation (only clear path)
//

import CoreLocation
import Foundation

struct PhysicalDeviceRunResult: Equatable, Sendable {
    var succeeded: Bool
    var message: String
    var verifiedLatitude: Double?
    var verifiedLongitude: Double?
    var durationSeconds: TimeInterval
    var combinedOutput: String
    var exitCode: Int32
    var assignmentTimestamp: String?
    var verificationTimestamp: String?
    var testMethodEndTimestamp: String?
    var xcodebuildExitTimestamp: String
    var executedLocationNil: Bool
}

@MainActor
final class PhysicalDeviceLocationRunner {
    static let setTestIdentifier =
        "ChangeMeDeviceUITests/LocationSessionUITests/testSetChangeMeLocation"
    static let clearTestIdentifier =
        "ChangeMeDeviceUITests/LocationSessionUITests/testClearChangeMeLocation"

    private let projectURL: URL

    init(projectURL: URL? = nil) {
        self.projectURL = projectURL ?? Self.locateProject()
    }

    var projectPath: String { projectURL.path }

    func applySet(
        coordinate: CLLocationCoordinate2D,
        deviceID: String,
        developerDirectory: URL
    ) async throws -> PhysicalDeviceRunResult {
        try LocationSessionControl.writeCommand(.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))

        let env: [String: String] = [
            "DEVELOPER_DIR": developerDirectory.path,
            "TEST_RUNNER_CHANGEME_ACTION": "set",
            "TEST_RUNNER_CHANGEME_LATITUDE": String(coordinate.latitude),
            "TEST_RUNNER_CHANGEME_LONGITUDE": String(coordinate.longitude),
            "CHANGEME_ACTION": "set",
            "CHANGEME_LATITUDE": String(coordinate.latitude),
            "CHANGEME_LONGITUDE": String(coordinate.longitude)
        ]

        return try await runAutomation(
            testIdentifier: Self.setTestIdentifier,
            deviceID: deviceID,
            developerDirectory: developerDirectory,
            environment: env,
            expectVerifiedCoordinate: coordinate,
            executedLocationNil: false,
            requestedCoordinate: coordinate
        )
    }

    func applyClear(
        deviceID: String,
        developerDirectory: URL,
        previousCoordinate: CLLocationCoordinate2D?
    ) async throws -> PhysicalDeviceRunResult {
        try LocationSessionControl.writeCommand(.clear(
            previousLatitude: previousCoordinate?.latitude,
            previousLongitude: previousCoordinate?.longitude
        ))

        var env: [String: String] = [
            "DEVELOPER_DIR": developerDirectory.path,
            "TEST_RUNNER_CHANGEME_ACTION": "clear",
            "CHANGEME_ACTION": "clear"
        ]
        if let previousCoordinate {
            env["TEST_RUNNER_CHANGEME_PREV_LATITUDE"] = String(previousCoordinate.latitude)
            env["TEST_RUNNER_CHANGEME_PREV_LONGITUDE"] = String(previousCoordinate.longitude)
            env["CHANGEME_PREV_LATITUDE"] = String(previousCoordinate.latitude)
            env["CHANGEME_PREV_LONGITUDE"] = String(previousCoordinate.longitude)
        }

        return try await runAutomation(
            testIdentifier: Self.clearTestIdentifier,
            deviceID: deviceID,
            developerDirectory: developerDirectory,
            environment: env,
            expectVerifiedCoordinate: nil,
            executedLocationNil: true,
            requestedCoordinate: previousCoordinate
        )
    }

    // MARK: - Internals

    private func runAutomation(
        testIdentifier: String,
        deviceID: String,
        developerDirectory: URL,
        environment: [String: String],
        expectVerifiedCoordinate: CLLocationCoordinate2D?,
        executedLocationNil: Bool,
        requestedCoordinate: CLLocationCoordinate2D?
    ) async throws -> PhysicalDeviceRunResult {
        let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        guard FileManager.default.isExecutableFile(atPath: xcodebuild.path) else {
            throw AppError.xcodeToolsUnavailable("xcodebuild not found in \(developerDirectory.path)")
        }
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw AppError.xcodeToolsUnavailable("ChangeMe.xcodeproj not found at \(projectURL.path)")
        }

        let started = Date()
        let result = try await ProcessRunner.run(
            executable: xcodebuild,
            arguments: [
                "test",
                "-project", projectURL.path,
                "-scheme", "ChangeMeDevice",
                "-destination", "platform=iOS,id=\(deviceID)",
                "-only-testing:\(testIdentifier)",
                "-allowProvisioningUpdates"
            ],
            environment: environment
        )
        let exitStamp = ISO8601DateFormatter().string(from: Date())
        let duration = Date().timeIntervalSince(started)
        let output = result.combinedOutput

        let assignmentTS = Self.parseDiagTimestamp(prefix: "T0_assignment=", from: output)
            ?? Self.parseDiagTimestamp(prefix: "T0_clear_assignment=", from: output)
        let verificationTS = Self.parseDiagTimestamp(prefix: "T1_verified=", from: output)
        let methodEndTS = Self.parseDiagTimestamp(prefix: "T2_method_complete=", from: output)
            ?? Self.parseDiagTimestamp(prefix: "T2_clear_method_complete=", from: output)

        if let setup = Self.classifySetupFailure(in: output) {
            try? LocationSessionControl.writeStatus(
                .init(state: "failed", latitude: nil, longitude: nil, message: setup, updatedAt: .now)
            )
            return PhysicalDeviceRunResult(
                succeeded: false,
                message: setup,
                verifiedLatitude: nil,
                verifiedLongitude: nil,
                durationSeconds: duration,
                combinedOutput: output,
                exitCode: result.exitCode,
                assignmentTimestamp: assignmentTS,
                verificationTimestamp: verificationTS,
                testMethodEndTimestamp: methodEndTS,
                xcodebuildExitTimestamp: exitStamp,
                executedLocationNil: executedLocationNil
            )
        }

        if let expected = expectVerifiedCoordinate {
            if let match = Self.parseVerifiedCoordinate(from: output),
               abs(match.0 - expected.latitude) < 0.02,
               abs(match.1 - expected.longitude) < 0.02,
               output.contains("** TEST SUCCEEDED **") || result.succeeded {
                try? LocationSessionControl.writeStatus(
                    .init(
                        state: "injected",
                        latitude: match.0,
                        longitude: match.1,
                        message: "Injection verified; persistence unknown until manual check",
                        updatedAt: .now
                    )
                )
                try? LocationSessionControl.writePersistenceDiagnostics(
                    .init(
                        requestedLatitude: expected.latitude,
                        requestedLongitude: expected.longitude,
                        verifiedLatitude: match.0,
                        verifiedLongitude: match.1,
                        assignmentTimestamp: assignmentTS,
                        verificationTimestamp: verificationTS,
                        testMethodEndTimestamp: methodEndTS,
                        xcodebuildExitTimestamp: exitStamp,
                        executedLocationNil: false,
                        additionalTestsAfterward: false,
                        note: "Injection verified. Persistence unknown. Find My: manual verification required."
                    )
                )
                return PhysicalDeviceRunResult(
                    succeeded: true,
                    message: "Injection verified (persistence unknown)",
                    verifiedLatitude: match.0,
                    verifiedLongitude: match.1,
                    durationSeconds: duration,
                    combinedOutput: output,
                    exitCode: result.exitCode,
                    assignmentTimestamp: assignmentTS,
                    verificationTimestamp: verificationTS,
                    testMethodEndTimestamp: methodEndTS,
                    xcodebuildExitTimestamp: exitStamp,
                    executedLocationNil: false
                )
            }

            let message = "Physical XCTest did not verify the requested coordinate."
            try? LocationSessionControl.writeStatus(
                .init(state: "failed", latitude: expected.latitude, longitude: expected.longitude, message: message, updatedAt: .now)
            )
            return PhysicalDeviceRunResult(
                succeeded: false,
                message: message,
                verifiedLatitude: nil,
                verifiedLongitude: nil,
                durationSeconds: duration,
                combinedOutput: output,
                exitCode: result.exitCode,
                assignmentTimestamp: assignmentTS,
                verificationTimestamp: verificationTS,
                testMethodEndTimestamp: methodEndTS,
                xcodebuildExitTimestamp: exitStamp,
                executedLocationNil: false
            )
        }

        // clear
        let clearedOK =
            (output.contains("** TEST SUCCEEDED **") || result.succeeded)
            && (output.contains("ChangeMeDevice after clear") || output.contains("passed"))
        let after = Self.parseAfterClearCoordinate(from: output)
        let message = clearedOK
            ? "Physical simulated location cleared"
            : "Physical clear via XCTest failed."
        try? LocationSessionControl.writeStatus(
            .init(
                state: clearedOK ? "cleared" : "failed",
                latitude: after?.0,
                longitude: after?.1,
                message: message,
                updatedAt: .now
            )
        )
        if let requested = requestedCoordinate {
            try? LocationSessionControl.writePersistenceDiagnostics(
                .init(
                    requestedLatitude: requested.latitude,
                    requestedLongitude: requested.longitude,
                    verifiedLatitude: after?.0,
                    verifiedLongitude: after?.1,
                    assignmentTimestamp: assignmentTS,
                    verificationTimestamp: verificationTS,
                    testMethodEndTimestamp: methodEndTS,
                    xcodebuildExitTimestamp: exitStamp,
                    executedLocationNil: true,
                    additionalTestsAfterward: false,
                    note: clearedOK ? "Clear succeeded" : "Clear failed"
                )
            )
        }
        return PhysicalDeviceRunResult(
            succeeded: clearedOK,
            message: message,
            verifiedLatitude: after?.0,
            verifiedLongitude: after?.1,
            durationSeconds: duration,
            combinedOutput: output,
            exitCode: result.exitCode,
            assignmentTimestamp: assignmentTS,
            verificationTimestamp: verificationTS,
            testMethodEndTimestamp: methodEndTS,
            xcodebuildExitTimestamp: exitStamp,
            executedLocationNil: true
        )
    }

    static func classifySetupFailure(in output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("no accounts") {
            return "Xcode has no signed-in Apple ID for CLI provisioning. Open Xcode → Settings → Accounts, then run Product → Test once on the iPhone."
        }
        if lower.contains("xctrunner") && (lower.contains("no profiles") || lower.contains("doesn't match")) {
            return "UITest runner provisioning profile missing. In Xcode, select ChangeMeDevice → your iPhone → Product → Test once."
        }
        if lower.contains("developer mode") {
            return "Developer Mode is disabled on the iPhone."
        }
        if lower.contains("not connected") || lower.contains("timed out waiting") || lower.contains("unable to find a destination") {
            return "Physical iPhone destination unavailable. Reconnect USB and unlock the device."
        }
        if lower.contains("ios ") && lower.contains("is not installed") {
            return "iOS platform support is missing. Install it from Xcode → Settings → Components."
        }
        return nil
    }

    static func parseVerifiedCoordinate(from output: String) -> (Double, Double)? {
        let pattern = #"ChangeMeDevice verified[^:]*:\s*([-+]?\d+\.?\d*)\s*,\s*([-+]?\d+\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let latRange = Range(match.range(at: 1), in: output),
              let lonRange = Range(match.range(at: 2), in: output),
              let lat = Double(output[latRange]),
              let lon = Double(output[lonRange])
        else { return nil }
        return (lat, lon)
    }

    static func parseAfterClearCoordinate(from output: String) -> (Double, Double)? {
        let pattern = #"ChangeMeDevice after clear:\s*([-+]?\d+\.?\d*)\s*,\s*([-+]?\d+\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let latRange = Range(match.range(at: 1), in: output),
              let lonRange = Range(match.range(at: 2), in: output),
              let lat = Double(output[latRange]),
              let lon = Double(output[lonRange])
        else { return nil }
        return (lat, lon)
    }

    static func parseDiagTimestamp(prefix: String, from output: String) -> String? {
        // ChangeMeDIAG T0_assignment=2026-07-25T19:00:00Z ...
        guard let range = output.range(of: "ChangeMeDIAG \(prefix)") else { return nil }
        let after = output[range.upperBound...]
        let end = after.firstIndex(where: { $0.isWhitespace || $0 == "\n" }) ?? after.endIndex
        let value = String(after[..<end])
        return value.isEmpty ? nil : value
    }

    static func hasUITestRunnerProfile() -> Bool {
        // Diagnostics only — never use this to disable Start.
        // .mobileprovision files are CMS/binary; String decoding is unreliable.
        let dirs = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
        ]
        let needle = Data("ChangeMeDeviceUITests.xctrunner".utf8)
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension == "mobileprovision" {
                if let data = try? Data(contentsOf: file), data.range(of: needle) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func locateProject() -> URL {
        if let fromEnv = ProcessInfo.processInfo.environment["CHANGEME_XCODEPROJ"],
           FileManager.default.fileExists(atPath: fromEnv) {
            return URL(fileURLWithPath: fromEnv)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ChangeMe.xcodeproj")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }

        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("ChangeMe.xcodeproj")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return cwd
    }
}

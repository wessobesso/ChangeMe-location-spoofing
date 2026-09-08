//
//  LocationSimulationService.swift
//  ChangeMe
//

import AppKit
import CoreLocation
import Foundation

/// What ChangeMe can do with the installed Xcode tooling.
enum LocationSimulationCapability: Equatable, Sendable {
    case simulatorCLI
    case physicalDeviceCLI
    case physicalDeviceXCTest
    case physicalDeviceRequiresXcodeDebugSession
    case unavailable(reason: String)

    var summary: String {
        switch self {
        case .simulatorCLI:
            return "Simulator CLI (simctl location)"
        case .physicalDeviceCLI:
            return "Physical-device CLI (devicectl location)"
        case .physicalDeviceXCTest:
            return "Physical XCTest session (long-lived XCUIDevice.location)"
        case .physicalDeviceRequiresXcodeDebugSession:
            return "Manual Xcode Debug → Simulate Location"
        case .unavailable(let reason):
            return "Unavailable: \(reason)"
        }
    }

    var usesAutomaticStart: Bool {
        switch self {
        case .simulatorCLI, .physicalDeviceCLI, .physicalDeviceXCTest:
            return true
        default:
            return false
        }
    }
}

enum SimulationStartOutcome: Equatable, Sendable {
    case started
    case preparedManualXcodeSession(PreparedManualXcodeSession)
}

@MainActor
final class LocationSimulationService {
    private(set) var activeDevice: ConnectedDevice?
    private(set) var lastGPXURL: URL?
    private(set) var lastCapability: LocationSimulationCapability?
    private(set) var lastManualSession: PreparedManualXcodeSession?
    private(set) var lastPhysicalRun: PhysicalDeviceRunResult?
    private(set) var physicalSessionMetrics: PhysicalSessionMetrics?
    private(set) var lastPhysicalStopResult: PhysicalSessionStopResult?
    private var tools: DeveloperToolsStatus
    private var backend: SimulationBackend = .none
    private var lastSimulatedCoordinate: CLLocationCoordinate2D?
    private let physicalRunner = PhysicalDeviceLocationRunner()
    private let physicalSession = PhysicalDeviceSessionController()

    var onPhysicalSessionLost: (() -> Void)?
    var onPhysicalStageChanged: ((PhysicalSessionStage) -> Void)?
    var activeXcodebuildPID: Int32? { cachedXcodebuildPID }
    var physicalSessionEndpoint: String { cachedPhysicalEndpoint }
    var physicalSessionAuthenticationActive: Bool { cachedPhysicalAuthActive }
    var ownedPhysicalProcessRunning: Bool { cachedOwnedProcessRunning }

    private var cachedPhysicalEndpoint = "not connected"
    private var cachedPhysicalAuthActive = false
    private var cachedOwnedProcessRunning = false
    private var cachedXcodebuildPID: Int32?

    func refreshPhysicalSessionSnapshot() async {
        cachedPhysicalEndpoint = await physicalSession.sessionEndpointDescription
        cachedPhysicalAuthActive = await physicalSession.hasAuthentication
        cachedOwnedProcessRunning = await physicalSession.ownedProcessIsRunning
        cachedXcodebuildPID = await physicalSession.xcodebuildPID
        physicalSessionMetrics = await physicalSession.metrics
    }

    /// Fast preflight before spending ~20s launching the runner.
    /// Intentionally does NOT speculate about UITest provisioning-profile cache files.
    /// Product → Test / xcodebuild remains the authoritative provisioning check.
    ///
    /// Must remain safe to call from SwiftUI body / MainActor getters: never spawn
    /// Process / arp / xcrun here (that blocked the UI after location permission).
    func physicalSetupIssue(for device: ConnectedDevice) -> String? {
        if !tools.hasXcode || tools.xcodeDeveloperDirectory == nil {
            return "Install the full Xcode app from the App Store (ChangeMe uses Xcode.app, not Command Line Tools alone)."
        }
        if device.isSimulator { return nil }
        if !device.isAvailable {
            return "The selected iPhone is unavailable. Reconnect USB and unlock the device."
        }
        if let status = device.developerModeStatus?.lowercased(), status == "disabled" {
            return "Enable Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode)."
        }
        // Lightweight getifaddrs-only check — no Process. Full peer ARP discovery
        // still runs asynchronously when Start Simulation begins.
        if !PhysicalDeviceSessionController.hasUSBDeveloperNetworkInterface() {
            return "USB developer network not detected. Keep the iPhone connected by USB."
        }
        return nil
    }

    private enum SimulationBackend {
        case none
        case simctl
        case devicectlLocation
        case physicalXCTestSession
    }

    init(tools: DeveloperToolsStatus = DeveloperToolsStatus(
        xcodeDeveloperDirectory: nil,
        xcrunURL: nil,
        hasXcode: false,
        hasDevicectl: false,
        hasSimctl: false,
        hasDevicectlLocationSimulate: false,
        xcodeVersionString: nil,
        diagnosticMessage: nil
    )) {
        self.tools = tools
    }

    func updateTools(_ tools: DeveloperToolsStatus) {
        self.tools = tools
    }

    func capability(for device: ConnectedDevice) -> LocationSimulationCapability {
        if device.isSimulator {
            return tools.hasSimctl
                ? .simulatorCLI
                : .unavailable(reason: "simctl location is unavailable.")
        }

        if tools.hasDevicectlLocationSimulate {
            return .physicalDeviceCLI
        }

        // Always attempt the proven XCTest session path for physical devices.
        // Do not gate on provisioning-profile filesystem scans (those blocked UI).
        return .physicalDeviceXCTest
    }

    func startSimulation(
        device: ConnectedDevice,
        coordinate: CLLocationCoordinate2D
    ) async throws -> SimulationStartOutcome {
        guard CoordinateValidation.isValid(coordinate) else {
            throw AppError.invalidCoordinates
        }

        guard let xcrun = tools.xcrunURL,
              let developerDir = tools.xcodeDeveloperDirectory
        else {
            throw AppError.xcodeToolsUnavailable(
                tools.diagnosticMessage
                    ?? "Install the full Xcode app and select it with xcode-select."
            )
        }

        if !device.isSimulator,
           let status = device.developerModeStatus?.lowercased(),
           status == "disabled" {
            throw AppError.developerModeUnavailable
        }

        let capability = capability(for: device)
        lastCapability = capability
        let env = ["DEVELOPER_DIR": developerDir.path]

        switch capability {
        case .simulatorCLI:
            lastGPXURL = try? GPXGenerator.generateWaypoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: "ChangeMe Simulated Location"
            )
            try await applySimctlLocation(
                xcrun: xcrun,
                environment: env,
                deviceID: device.id,
                coordinate: coordinate
            )
            activeDevice = device
            backend = .simctl
            lastSimulatedCoordinate = coordinate
            return .started

        case .physicalDeviceCLI:
            lastGPXURL = try? GPXGenerator.generateWaypoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: "ChangeMe Simulated Location"
            )
            try await applyDevicectlLocation(
                xcrun: xcrun,
                environment: env,
                deviceID: device.id,
                coordinate: coordinate
            )
            activeDevice = device
            backend = .devicectlLocation
            lastSimulatedCoordinate = coordinate
            return .started

        case .physicalDeviceXCTest:
            if let issue = physicalSetupIssue(for: device) {
                throw AppError.simulationStartFailed(deviceName: device.name, details: issue)
            }
            await physicalSession.setHandlers(
                onStageChanged: { [weak self] stage in
                    Task { @MainActor in
                        await self?.refreshPhysicalSessionSnapshot()
                        self?.onPhysicalStageChanged?(stage)
                    }
                },
                onSessionLost: { [weak self] in
                    Task { @MainActor in
                        await self?.refreshPhysicalSessionSnapshot()
                        self?.onPhysicalSessionLost?()
                    }
                }
            )
            do {
                try await physicalSession.startSession(
                    coordinate: coordinate,
                    deviceID: device.id,
                    developerDirectory: developerDir
                )
                activeDevice = device
                backend = .physicalXCTestSession
                lastSimulatedCoordinate = coordinate
                await refreshPhysicalSessionSnapshot()
                return .started
            } catch let error as AppError {
                throw error
            } catch {
                throw AppError.simulationStartFailed(
                    deviceName: device.name,
                    details: error.localizedDescription
                )
            }

        case .physicalDeviceRequiresXcodeDebugSession:
            let session = try prepareManualXcodeSession(device: device, coordinate: coordinate)
            lastManualSession = session
            return .preparedManualXcodeSession(session)

        case .unavailable(let reason):
            throw AppError.simulationUnsupported(reason)
        }
    }

    func updateSimulation(coordinate: CLLocationCoordinate2D) async throws {
        guard let device = activeDevice else {
            throw AppError.simulationUnsupported("No active automated simulation to update.")
        }
        guard CoordinateValidation.isValid(coordinate) else {
            throw AppError.invalidCoordinates
        }

        guard let xcrun = tools.xcrunURL,
              let developerDir = tools.xcodeDeveloperDirectory
        else {
            throw AppError.xcodeToolsUnavailable("Xcode developer tools became unavailable.")
        }

        let env = ["DEVELOPER_DIR": developerDir.path]
        lastGPXURL = try? GPXGenerator.generateWaypoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )

        switch backend {
        case .simctl:
            try await applySimctlLocation(
                xcrun: xcrun,
                environment: env,
                deviceID: device.id,
                coordinate: coordinate
            )
            lastSimulatedCoordinate = coordinate
        case .devicectlLocation:
            try await applyDevicectlLocation(
                xcrun: xcrun,
                environment: env,
                deviceID: device.id,
                coordinate: coordinate
            )
            lastSimulatedCoordinate = coordinate
        case .physicalXCTestSession:
            do {
                try await physicalSession.updateCoordinate(coordinate)
                lastSimulatedCoordinate = coordinate
                await refreshPhysicalSessionSnapshot()
            } catch let error as AppError {
                throw AppError.locationUpdateFailed(error.technicalDetails ?? error.localizedDescription)
            } catch {
                throw AppError.locationUpdateFailed(error.localizedDescription)
            }
        case .none:
            throw AppError.simulationUnsupported("Simulation backend is not active.")
        }
    }

    func stopSimulation() async throws {
        guard let device = activeDevice else {
            backend = .none
            lastSimulatedCoordinate = nil
            return
        }

        let stoppingBackend = backend

        guard let xcrun = tools.xcrunURL,
              let developerDir = tools.xcodeDeveloperDirectory
        else {
            throw AppError.simulationStopFailed("Xcode developer tools are unavailable.")
        }

        let env = ["DEVELOPER_DIR": developerDir.path]

        switch stoppingBackend {
        case .simctl:
            let result = try await ProcessRunner.run(
                executable: xcrun,
                arguments: ["simctl", "location", device.id, "clear"],
                environment: env
            )
            if !result.succeeded {
                throw AppError.simulationStopFailed(
                    result.combinedOutput.isEmpty
                        ? "simctl location clear exited \(result.exitCode)."
                        : result.combinedOutput
                )
            }
        case .devicectlLocation:
            let clearAttempts = [
                ["devicectl", "device", "simulate", "location", "clear", "--device", device.id],
                ["devicectl", "device", "location", "clear", "--device", device.id]
            ]
            var lastError = ""
            var cleared = false
            for args in clearAttempts {
                let result = try await ProcessRunner.run(
                    executable: xcrun,
                    arguments: args,
                    environment: env
                )
                if result.succeeded {
                    cleared = true
                    break
                }
                lastError = result.combinedOutput
            }
            if !cleared {
                throw AppError.simulationStopFailed(
                    lastError.isEmpty
                        ? "Could not clear simulated location via devicectl."
                        : lastError
                )
            }
        case .physicalXCTestSession:
            let result = await physicalSession.stopSession(sendStop: true, force: false)
            await refreshPhysicalSessionSnapshot()
            activeDevice = nil
            backend = .none
            lastSimulatedCoordinate = nil
            GPXGenerator.cleanupTemporaryFiles()
            lastGPXURL = nil
            lastPhysicalStopResult = result
            return
        case .none:
            break
        }

        // Only mark inactive after clear/stop succeeds.
        activeDevice = nil
        backend = .none
        lastSimulatedCoordinate = nil
        lastPhysicalStopResult = nil
        GPXGenerator.cleanupTemporaryFiles()
        lastGPXURL = nil
    }

    func forceEndPhysicalSession() async {
        _ = await physicalSession.forceEndSession()
        await refreshPhysicalSessionSnapshot()
        activeDevice = nil
        backend = .none
        lastSimulatedCoordinate = nil
    }

    /// One-shot clear when the long-lived session is already gone.
    func emergencyClearLocation(device: ConnectedDevice? = nil) async throws {
        guard let developerDir = tools.xcodeDeveloperDirectory else {
            throw AppError.xcodeToolsUnavailable("Xcode developer tools are unavailable.")
        }
        guard let device = device ?? activeDevice else {
            throw AppError.noDeviceSelected
        }
        let result = try await physicalSession.emergencyClear(
            deviceID: device.id,
            developerDirectory: developerDir,
            previousCoordinate: lastSimulatedCoordinate
        )
        lastPhysicalRun = result
        guard result.succeeded else {
            throw AppError.simulationStopFailed(Self.compactDetails(from: result))
        }
        await physicalSession.stopSession(sendStop: false, force: true)
        activeDevice = nil
        backend = .none
        lastSimulatedCoordinate = nil
    }

    func openProjectInXcode() {
        NSWorkspace.shared.open(physicalRunner.projectPath.hasSuffix("xcodeproj")
            ? URL(fileURLWithPath: physicalRunner.projectPath)
            : projectURL())
    }

    func revealGeneratedGPX() {
        guard let gpx = lastGPXURL ?? lastManualSession?.gpxURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([gpx])
    }

    // MARK: - Manual session fallback

    private func prepareManualXcodeSession(
        device: ConnectedDevice,
        coordinate: CLLocationCoordinate2D
    ) throws -> PreparedManualXcodeSession {
        let gpx = try GPXGenerator.generateWaypoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            name: "ChangeMe Selected Location"
        )
        lastGPXURL = gpx

        try LocationSessionControl.writeCommand(.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
        try LocationSessionControl.writeStatus(
            .init(
                state: "prepared",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                message: "Awaiting manual Xcode Debug → Simulate Location",
                updatedAt: .now
            )
        )

        return PreparedManualXcodeSession(
            deviceName: device.name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            gpxURL: gpx,
            projectURL: projectURL(),
            companionSchemeName: "ChangeMeDevice"
        )
    }

    private func projectURL() -> URL {
        URL(fileURLWithPath: physicalRunner.projectPath)
    }

    private static func compactDetails(from result: PhysicalDeviceRunResult) -> String {
        var lines: [String] = [
            result.message,
            "exit status: \(result.exitCode)",
            String(format: "duration: %.1fs", result.durationSeconds)
        ]
        let useful = result.combinedOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("error")
                    || lower.contains("failed")
                    || lower.contains("profile")
                    || lower.contains("account")
                    || lower.contains("changemedevice")
                    || lower.contains("test case")
            }
            .suffix(20)
        if !useful.isEmpty {
            lines.append("—")
            lines.append(contentsOf: useful)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Backends

    private func applySimctlLocation(
        xcrun: URL,
        environment: [String: String],
        deviceID: String,
        coordinate: CLLocationCoordinate2D
    ) async throws {
        let pair = String(format: "%.8f,%.8f", coordinate.latitude, coordinate.longitude)
        let result = try await ProcessRunner.run(
            executable: xcrun,
            arguments: ["simctl", "location", deviceID, "set", pair],
            environment: environment
        )
        if !result.succeeded {
            throw AppError.commandExecutionFailed(
                result.combinedOutput.isEmpty
                    ? "simctl location set failed (\(result.exitCode)). Is the simulator booted?"
                    : result.combinedOutput
            )
        }
    }

    private func applyDevicectlLocation(
        xcrun: URL,
        environment: [String: String],
        deviceID: String,
        coordinate: CLLocationCoordinate2D
    ) async throws {
        let lat = String(format: "%.8f", coordinate.latitude)
        let lon = String(format: "%.8f", coordinate.longitude)

        let attempts: [[String]] = [
            [
                "devicectl", "device", "simulate", "location", "coordinate",
                "--device", deviceID,
                "--latitude", lat,
                "--longitude", lon
            ],
            [
                "devicectl", "device", "location", "set",
                "--device", deviceID,
                "\(lat),\(lon)"
            ]
        ]

        var lastOutput = ""
        for args in attempts {
            let result = try await ProcessRunner.run(
                executable: xcrun,
                arguments: args,
                environment: environment
            )
            if result.succeeded {
                return
            }
            lastOutput = result.combinedOutput
        }

        throw AppError.simulationUnsupported(
            lastOutput.isEmpty
                ? "devicectl location simulation commands were not accepted by this Xcode."
                : lastOutput
        )
    }
}

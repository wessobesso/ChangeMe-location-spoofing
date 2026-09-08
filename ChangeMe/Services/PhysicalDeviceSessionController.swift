//
//  PhysicalDeviceSessionController.swift
//  ChangeMe
//
//  Owns one long-lived physical XCTest session. The UITest listens on-device;
//  ChangeMe connects over USB link-local (preferred). Production physical backend.
//

import CoreLocation
import Darwin
import Foundation
import Network
import Security

struct PhysicalSessionMetrics: Sendable {
    var startupSeconds: TimeInterval?
    var runnerLaunchSeconds: TimeInterval?
    var connectionSeconds: TimeInterval?
    var firstInjectionSeconds: TimeInterval?
    var lastUpdateSeconds: TimeInterval?
    var stopSeconds: TimeInterval?
    var xcodebuildPID: Int32?
    var sessionStartedAt: Date?
    var lastAppliedAt: Date?
    var endpoint: String?
    var authenticationActive: Bool = false

    // Evidence-only session health (Goal B). Do not auto-flip Simulation Active from these yet.
    var runnerConnected: Bool = false
    var lastCommandAppliedAt: Date?
    var lastVerifiedCoordinate: CLLocationCoordinate2D?
    var lastVerifiedAt: Date?
    var lastSampleLatitude: Double?
    var lastSampleLongitude: Double?
    var lastSampleHorizontalAccuracy: Double?
    var lastSampleAt: Date?
    var sampleCount: Int = 0

    var sessionDurationSeconds: TimeInterval? {
        guard let sessionStartedAt else { return nil }
        return Date().timeIntervalSince(sessionStartedAt)
    }
}

struct CompanionLocationSample: Equatable, Sendable {
    var elapsedSeconds: TimeInterval
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var xctestAlive: Bool
    var tcpAlive: Bool
    var message: String?
}

enum PhysicalSessionStage: Equatable, Sendable {
    case idle
    case preparing
    case launchingTestRunner
    case waitingForConnection
    case applyingInitialLocation
    case active
    case updating
    case stopping
}

enum PhysicalSessionStopResult: Equatable, Sendable {
    case cleared
    case forceEndedWithoutClearConfirmation
}

/// Physical XCTest session engine.
///
/// Must NOT be MainActor-isolated. Start/Update/Stop perform Process + socket waits;
/// running those on MainActor deadlocks MapKit's main-thread `renderSceneSync` /
/// `barrierSync` (beach ball while Start Simulation is in progress).
actor PhysicalDeviceSessionController {
    static let sessionTestIdentifier =
        "ChangeMeDeviceUITests/LocationSessionUITests/testRunChangeMeLocationSession"
    static let defaultListenPort: UInt16 = 53271

    /// Timeouts for production Start.
    static let runnerLaunchTimeout: TimeInterval = 90
    static let connectionTimeout: TimeInterval = 30
    static let initialAppliedTimeout: TimeInterval = 45
    static let updateTimeout: TimeInterval = 15
    static let stopAckTimeout: TimeInterval = 45
    static let processExitGrace: TimeInterval = 25

    private let projectURL: URL
    private let client = LocationSessionClient()
    private var process: ManagedProcess?
    private var monitorTask: Task<Void, Never>?
    private var sessionToken = ""
    private var listenPort: UInt16 = defaultListenPort
    private var deviceHost: String?
    private var ownedDeviceID: String?

    private(set) var stage: PhysicalSessionStage = .idle
    private(set) var isSessionActive = false
    private(set) var lastAppliedCoordinate: CLLocationCoordinate2D?
    private(set) var metrics = PhysicalSessionMetrics()
    private(set) var lastErrorMessage: String?

    private var onStageChanged: (@Sendable (PhysicalSessionStage) -> Void)?
    private var onSessionLost: (@Sendable () -> Void)?
    private var onApplied: (@Sendable (CLLocationCoordinate2D) -> Void)?

    init(projectURL: URL? = nil) {
        self.projectURL = projectURL ?? Self.locateProject()
    }

    func setHandlers(
        onStageChanged: (@Sendable (PhysicalSessionStage) -> Void)?,
        onSessionLost: (@Sendable () -> Void)?,
        onApplied: (@Sendable (CLLocationCoordinate2D) -> Void)? = nil
    ) {
        self.onStageChanged = onStageChanged
        self.onSessionLost = onSessionLost
        self.onApplied = onApplied
    }

    var projectPath: String { projectURL.path }
    var xcodebuildPID: Int32? { process?.processIdentifier }
    var ownedProcessIsRunning: Bool { process?.isRunning == true }
    var sessionEndpointDescription: String {
        metrics.endpoint ?? "not connected"
    }
    var hasAuthentication: Bool { metrics.authenticationActive }

    func startSession(
        coordinate: CLLocationCoordinate2D,
        deviceID: String,
        developerDirectory: URL
    ) async throws {
        // Single-session guarantee.
        if isSessionActive || stage == .stopping || stage.isStarting {
            throw AppError.commandExecutionFailed("A physical developer session is already in progress.")
        }

        await cleanupOwnedResources(sendStop: false, forceKillAfterGrace: false)

        let startedAt = Date()
        metrics = PhysicalSessionMetrics()
        sessionToken = Self.makeSessionToken()
        listenPort = Self.defaultListenPort
        ownedDeviceID = deviceID
        setStage(.preparing)

        do {
            let host = try await Self.discoverReachableDeviceIPv4(port: listenPort)
            deviceHost = host
            metrics.endpoint = "\(host):\(listenPort)"

            setStage(.launchingTestRunner)
            let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
            let env: [String: String] = [
                "DEVELOPER_DIR": developerDirectory.path,
                "TEST_RUNNER_CHANGEME_PORT": "\(listenPort)",
                "TEST_RUNNER_CHANGEME_TOKEN": sessionToken,
                "TEST_RUNNER_CHANGEME_LATITUDE": String(coordinate.latitude),
                "TEST_RUNNER_CHANGEME_LONGITUDE": String(coordinate.longitude),
                "CHANGEME_PORT": "\(listenPort)",
                "CHANGEME_TOKEN": sessionToken,
                "CHANGEME_LATITUDE": String(coordinate.latitude),
                "CHANGEME_LONGITUDE": String(coordinate.longitude)
            ]

            let managed = ManagedProcess(
                executable: xcodebuild,
                arguments: [
                    "test",
                    "-project", projectURL.path,
                    "-scheme", "ChangeMeDevice",
                    "-destination", "platform=iOS,id=\(deviceID)",
                    "-only-testing:\(Self.sessionTestIdentifier)",
                    "-allowProvisioningUpdates"
                ],
                environment: env,
                currentDirectory: projectURL.deletingLastPathComponent()
            )
            try managed.start()
            process = managed
            metrics.xcodebuildPID = managed.processIdentifier
            SessionOrphanStore.save(
                pid: managed.processIdentifier,
                sessionToken: sessionToken,
                deviceID: deviceID
            )
            metrics.runnerLaunchSeconds = Date().timeIntervalSince(startedAt)

            // Wait for on-device listener.
            let listenDeadline = Date().addingTimeInterval(Self.runnerLaunchTimeout)
            var sawListening = false
            while Date() < listenDeadline {
                let output = managed.combinedOutputSnapshot()
                if output.contains("ChangeMeDIAG listening port=") {
                    sawListening = true
                    break
                }
                if !managed.isRunning { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !sawListening {
                throw AppError.simulationStartFailed(
                    deviceName: "iPhone",
                    details: """
                    Developer session runner did not become ready in time.
                    ---
                    \(managed.combinedOutputSnapshot().suffix(2500))
                    """
                )
            }

            setStage(.waitingForConnection)
            let connectionStarted = Date()
            var connected = false
            var lastConnectError: Error?
            let connectDeadline = Date().addingTimeInterval(Self.connectionTimeout)
            while Date() < connectDeadline {
                do {
                    try await client.connect(host: host, port: listenPort, timeout: 3)
                    connected = true
                    break
                } catch {
                    lastConnectError = error
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            guard connected else {
                throw AppError.simulationStartFailed(
                    deviceName: "iPhone",
                    details: """
                    Could not connect to the iPhone developer session over USB.
                    \(lastConnectError?.localizedDescription ?? "")
                    ---
                    \(managed.combinedOutputSnapshot().suffix(2000))
                    """
                )
            }
            metrics.connectionSeconds = Date().timeIntervalSince(connectionStarted)
            metrics.authenticationActive = true
            try await client.send(.hello(token: sessionToken))

            setStage(.applyingInitialLocation)
            let ready = await client.awaitMessage(types: ["READY", "ERROR"], timeout: Self.initialAppliedTimeout)
            if ready?.type == "ERROR" {
                throw AppError.simulationStartFailed(
                    deviceName: "iPhone",
                    details: ready?.message ?? "Session rejected the start command."
                )
            }
            guard let ready, let lat = ready.latitude, let lon = ready.longitude else {
                throw AppError.simulationStartFailed(
                    deviceName: "iPhone",
                    details: "iPhone connected but did not confirm the initial location."
                )
            }

            let applied = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lastAppliedCoordinate = applied
            metrics.lastAppliedAt = .now
            metrics.lastCommandAppliedAt = .now
            metrics.lastVerifiedCoordinate = applied
            metrics.lastVerifiedAt = .now
            metrics.runnerConnected = true
            metrics.sessionStartedAt = .now
            metrics.firstInjectionSeconds = Date().timeIntervalSince(startedAt)
            metrics.startupSeconds = metrics.firstInjectionSeconds
            isSessionActive = true
            setStage(.active)
            publishApplied(applied)

            let monitored = managed
            monitorTask = Task {
                let code = await monitored.waitUntilExit()
                await self.handleOwnedProcessExit(code)
            }
        } catch {
            await cleanupOwnedResources(sendStop: false, forceKillAfterGrace: true)
            setStage(.idle)
            throw error
        }
    }

    private func handleOwnedProcessExit(_ code: Int32) {
        guard isSessionActive else { return }
        isSessionActive = false
        metrics.authenticationActive = false
        metrics.runnerConnected = false
        lastErrorMessage = "Developer session ended unexpectedly (\(code))"
        client.disconnect()
        setStage(.idle)
        publishSessionLost()
    }

    /// Ask the UITest to read ChangeMeDevice Core Location without reassigning XCUIDevice.location.
    func sampleCompanionLocation(timeout: TimeInterval = 20) async -> CompanionLocationSample {
        let elapsed = metrics.sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let xctestAlive = ownedProcessIsRunning
        let tcpAlive = client.isConnected && isSessionActive
        guard tcpAlive else {
            return CompanionLocationSample(
                elapsedSeconds: elapsed,
                latitude: nil,
                longitude: nil,
                horizontalAccuracy: nil,
                xctestAlive: xctestAlive,
                tcpAlive: false,
                message: "tcp_not_connected"
            )
        }
        let id = UUID().uuidString
        do {
            try await client.send(.sample(token: sessionToken, id: id))
            let result = await client.awaitMessage(types: ["SAMPLE_RESULT", "ERROR"], timeout: timeout)
            if result?.type == "ERROR" {
                return CompanionLocationSample(
                    elapsedSeconds: elapsed,
                    latitude: nil,
                    longitude: nil,
                    horizontalAccuracy: nil,
                    xctestAlive: xctestAlive,
                    tcpAlive: client.isConnected,
                    message: result?.message ?? "sample_error"
                )
            }
            let sample = CompanionLocationSample(
                elapsedSeconds: result?.elapsedSeconds ?? elapsed,
                latitude: result?.latitude,
                longitude: result?.longitude,
                horizontalAccuracy: result?.horizontalAccuracy,
                xctestAlive: xctestAlive,
                tcpAlive: client.isConnected,
                message: result?.message
            )
            metrics.lastSampleLatitude = sample.latitude
            metrics.lastSampleLongitude = sample.longitude
            metrics.lastSampleHorizontalAccuracy = sample.horizontalAccuracy
            metrics.lastSampleAt = .now
            metrics.sampleCount += 1
            if let lat = sample.latitude, let lon = sample.longitude {
                metrics.lastVerifiedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                metrics.lastVerifiedAt = .now
            }
            return sample
        } catch {
            return CompanionLocationSample(
                elapsedSeconds: elapsed,
                latitude: nil,
                longitude: nil,
                horizontalAccuracy: nil,
                xctestAlive: xctestAlive,
                tcpAlive: client.isConnected,
                message: error.localizedDescription
            )
        }
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) async throws {
        guard isSessionActive, client.isConnected else {
            throw AppError.simulationUnsupported("No active physical location session.")
        }
        setStage(.updating)
        let started = Date()
        let id = UUID().uuidString
        do {
            try await client.send(
                .set(
                    id: id,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    token: sessionToken
                )
            )
            let applied = await client.awaitMessage(types: ["APPLIED", "ERROR"], timeout: Self.updateTimeout)
            if applied?.type == "ERROR" {
                setStage(.active)
                throw AppError.commandExecutionFailed(applied?.message ?? "Location update failed.")
            }
            guard let applied, let lat = applied.latitude, let lon = applied.longitude else {
                setStage(.active)
                throw AppError.commandExecutionFailed("Location update timed out.")
            }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lastAppliedCoordinate = coord
            metrics.lastAppliedAt = .now
            metrics.lastCommandAppliedAt = .now
            metrics.lastVerifiedCoordinate = coord
            metrics.lastVerifiedAt = .now
            metrics.lastUpdateSeconds = Date().timeIntervalSince(started)
            setStage(.active)
            publishApplied(coord)
        } catch {
            // Keep session alive unless the socket is dead.
            if !client.isConnected {
                isSessionActive = false
                metrics.authenticationActive = false
                setStage(.idle)
                publishSessionLost()
            } else {
                setStage(.active)
            }
            throw error
        }
    }

    @discardableResult
    func stopSession(sendStop: Bool = true, force: Bool = false) async -> PhysicalSessionStopResult {
        setStage(.stopping)
        let started = Date()
        monitorTask?.cancel()
        monitorTask = nil

        var clearedConfirmed = false
        if sendStop, client.isConnected {
            try? await client.send(.stop(token: sessionToken))
            if await client.awaitMessage(types: ["STOPPED"], timeout: Self.stopAckTimeout) != nil {
                clearedConfirmed = true
            }
        }

        client.disconnect()
        metrics.authenticationActive = false
        metrics.runnerConnected = false

        if let process, process.isRunning {
            let exitTask = Task { await process.waitUntilExit() }
            let result = await withTaskGroup(of: Int32?.self) { group in
                group.addTask { await exitTask.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(Self.processExitGrace))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if result == nil, process.isRunning {
                if force || !clearedConfirmed {
                    process.terminateGracefully()
                    _ = await process.waitUntilExit()
                } else {
                    process.terminateGracefully()
                    _ = await process.waitUntilExit()
                }
            }
        }

        process = nil
        isSessionActive = false
        deviceHost = nil
        sessionToken = ""
        ownedDeviceID = nil
        metrics.stopSeconds = Date().timeIntervalSince(started)
        metrics.sessionStartedAt = nil
        SessionOrphanStore.clear()
        setStage(.idle)

        if clearedConfirmed {
            return .cleared
        }
        return .forceEndedWithoutClearConfirmation
    }

    func forceEndSession() async -> PhysicalSessionStopResult {
        await stopSession(sendStop: true, force: true)
    }

    func emergencyClear(
        deviceID: String,
        developerDirectory: URL,
        previousCoordinate: CLLocationCoordinate2D?
    ) async throws -> PhysicalDeviceRunResult {
        let projectURL = self.projectURL
        let runner = await MainActor.run {
            PhysicalDeviceLocationRunner(projectURL: projectURL)
        }
        return try await runner.applyClear(
            deviceID: deviceID,
            developerDirectory: developerDirectory,
            previousCoordinate: previousCoordinate
        )
    }

    // MARK: - Internals

    private func setStage(_ stage: PhysicalSessionStage) {
        self.stage = stage
        let callback = onStageChanged
        Task { @MainActor in
            callback?(stage)
        }
    }

    private func publishApplied(_ coordinate: CLLocationCoordinate2D) {
        let callback = onApplied
        Task { @MainActor in
            callback?(coordinate)
        }
    }

    private func publishSessionLost() {
        let callback = onSessionLost
        Task { @MainActor in
            callback?()
        }
    }

    private func cleanupOwnedResources(sendStop: Bool, forceKillAfterGrace: Bool) async {
        monitorTask?.cancel()
        monitorTask = nil
        if sendStop, client.isConnected {
            try? await client.send(.stop(token: sessionToken))
            _ = await client.awaitMessage(types: ["STOPPED"], timeout: 5)
        }
        client.disconnect()
        if let process, process.isRunning {
            if forceKillAfterGrace {
                try? await Task.sleep(for: .milliseconds(200))
                process.terminateGracefully()
                _ = await process.waitUntilExit()
            } else {
                process.terminateGracefully()
                _ = await process.waitUntilExit()
            }
        }
        self.process = nil
        isSessionActive = false
        metrics.authenticationActive = false
        sessionToken = ""
        deviceHost = nil
    }

    nonisolated private static func makeSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Discover USB link-local iPhone address(es) dynamically — never hard-code en14.
    /// Prefer 169.254/16 peers on active interfaces; validate TCP reachability when possible.
    static func discoverReachableDeviceIPv4(port: UInt16) async throws -> String {
        // ARP peer scan must not run on MainActor (Process.waitUntilExit).
        let candidates = await Task.detached(priority: .userInitiated) {
            discoverCandidateDeviceIPv4s()
        }.value
        guard !candidates.isEmpty else {
            throw AppError.commandExecutionFailed(
                "Could not find the iPhone on the USB developer network. Keep USB connected so a 169.254.* link-local address appears."
            )
        }

        // Prefer USB link-local; try connecting briefly. Listener may not be up yet during Start,
        // so fall back to first USB candidate without requiring connect success here.
        let usb = candidates.filter { $0.hasPrefix("169.254.") }
        let ordered = usb + candidates.filter { !$0.hasPrefix("169.254.") }
        return ordered[0]
    }

    /// UI-safe USB presence check (getifaddrs only — never spawns a Process).
    /// True when this Mac has an up IPv4 169.254.* address (typical USB developer network).
    nonisolated static func hasUSBDeveloperNetworkInterface() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_len)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            if String(cString: host).hasPrefix("169.254.") {
                return true
            }
        }
        return false
    }

    /// Peer discovery for session start (may spawn `arp`). Must not run on MainActor / SwiftUI body.
    nonisolated static func discoverCandidateDeviceIPv4s() -> [String] {
        let arp = (try? ProcessRunner.runSyncPublic(
            executable: URL(fileURLWithPath: "/usr/sbin/arp"),
            arguments: ["-a"],
            environment: nil
        ).stdout) ?? ""

        let pattern = #"\(([0-9.]+)\) at [^ ]+ on ([a-zA-Z0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(arp.startIndex..<arp.endIndex, in: arp)

        let activeInterfaces = activeInterfaceNames()
        var usb: [String] = []
        var other: [String] = []

        for match in regex.matches(in: arp, range: range) {
            guard let ipRange = Range(match.range(at: 1), in: arp),
                  let ifRange = Range(match.range(at: 2), in: arp)
            else { continue }
            let ip = String(arp[ipRange])
            let iface = String(arp[ifRange])
            if ip.hasPrefix("127.") { continue }
            // Only consider interfaces that are currently up when known.
            if !activeInterfaces.isEmpty && !activeInterfaces.contains(iface) { continue }

            if ip.hasPrefix("169.254.") {
                if !usb.contains(ip) { usb.append(ip) }
            } else if iface.hasPrefix("en") || iface.hasPrefix("bridge") {
                if !other.contains(ip) { other.append(ip) }
            }
        }
        return usb + other
    }

    nonisolated private static func activeInterfaceNames() -> Set<String> {
        var names = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return names }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_RUNNING) == IFF_RUNNING else { continue }
            names.insert(String(cString: ptr.pointee.ifa_name))
        }
        return names
    }

    nonisolated private static func locateProject() -> URL {
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

private extension PhysicalSessionStage {
    var isStarting: Bool {
        switch self {
        case .preparing, .launchingTestRunner, .waitingForConnection, .applyingInitialLocation:
            return true
        default:
            return false
        }
    }
}

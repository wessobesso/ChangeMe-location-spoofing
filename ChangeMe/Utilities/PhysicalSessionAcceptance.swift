//
//  PhysicalSessionAcceptance.swift
//  ChangeMe
//
//  Production Swift acceptance path (NOT the Python harness).
//  Launch: ChangeMe.app --acceptance-physical
//

import CoreLocation
import Foundation

enum PhysicalSessionAcceptance {
    @MainActor
    static func run() async -> Int32 {
        print("ChangeMeACCEPTANCE begin")
        let tools = await DeveloperToolsLocator.locate()
        guard let developerDir = tools.xcodeDeveloperDirectory else {
            print("ChangeMeACCEPTANCE FAIL missing Xcode")
            return 2
        }

        let discovery = DeviceDiscoveryService()
        let devices: [ConnectedDevice]
        do {
            devices = try await discovery.discoverDevices(tools: tools)
        } catch {
            print("ChangeMeACCEPTANCE FAIL device discovery \(error)")
            return 3
        }

        guard let device = devices.first(where: { !$0.isSimulator && $0.isAvailable }) else {
            print("ChangeMeACCEPTANCE FAIL no physical iPhone")
            return 4
        }
        print("ChangeMeACCEPTANCE device=\(device.name) id=\(device.id)")

        let controller = PhysicalDeviceSessionController()
        let cn = CLLocationCoordinate2D(latitude: 43.6426, longitude: -79.3871)
        let ts = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)

        let startBegan = Date()
        do {
            try await controller.startSession(
                coordinate: cn,
                deviceID: device.id,
                developerDirectory: developerDir
            )
        } catch {
            print("ChangeMeACCEPTANCE FAIL start \(error)")
            return 5
        }

        let startSeconds = Date().timeIntervalSince(startBegan)
        let pid = await controller.xcodebuildPID
        print("ChangeMeACCEPTANCE START_OK seconds=\(String(format: "%.1f", startSeconds)) pid=\(pid ?? -1)")
        if let applied = await controller.lastAppliedCoordinate {
            print("ChangeMeACCEPTANCE CN_TOWER=\(applied.latitude),\(applied.longitude)")
        }

        // Hold at least 2 minutes.
        print("ChangeMeACCEPTANCE HOLD begin 120s")
        try? await Task.sleep(for: .seconds(120))
        guard await controller.isSessionActive, await controller.ownedProcessIsRunning else {
            print("ChangeMeACCEPTANCE FAIL hold session died")
            return 6
        }
        print("ChangeMeACCEPTANCE HOLD_OK same_pid=\(await controller.xcodebuildPID == pid)")

        let updateBegan = Date()
        do {
            try await controller.updateCoordinate(ts)
        } catch {
            print("ChangeMeACCEPTANCE FAIL update \(error)")
            _ = await controller.stopSession(sendStop: true, force: true)
            return 7
        }
        let updateSeconds = Date().timeIntervalSince(updateBegan)
        let appliedTS = await controller.lastAppliedCoordinate
        print("ChangeMeACCEPTANCE TIMES_SQUARE=\(appliedTS?.latitude ?? 0),\(appliedTS?.longitude ?? 0)")
        print("ChangeMeACCEPTANCE UPDATE_LATENCY=\(String(format: "%.1f", updateSeconds))s")
        print("ChangeMeACCEPTANCE SAME_PID=\(await controller.xcodebuildPID == pid)")

        let stopBegan = Date()
        let stopResult = await controller.stopSession(sendStop: true, force: false)
        let stopSeconds = Date().timeIntervalSince(stopBegan)
        print("ChangeMeACCEPTANCE STOP result=\(stopResult) seconds=\(String(format: "%.1f", stopSeconds))")

        let orphan = await controller.ownedProcessIsRunning
        print("ChangeMeACCEPTANCE ORPHAN=\(orphan)")
        print("ChangeMeACCEPTANCE endpoint=\(await controller.sessionEndpointDescription)")
        print("ChangeMeACCEPTANCE DONE")
        return (stopResult == .cleared && !orphan) ? 0 : 8
    }

    /// 10-minute no-refresh hold: Times Square, SAMPLE companion Core Location every 15s.
    /// Does NOT reassign XCUIDevice.location during the hold.
    /// Launch: ChangeMe.app --hold-sample-physical
    @MainActor
    static func runHoldSampleNoRefresh() async -> Int32 {
        let target = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)
        let holdSeconds: TimeInterval = 10 * 60
        let sampleInterval: TimeInterval = 15
        let matchTolerance = 0.01

        print("ChangeMeHOLD begin target=TimesSquare \(target.latitude),\(target.longitude)")
        print("ChangeMeHOLD interval=\(Int(sampleInterval))s duration=\(Int(holdSeconds))s refresh=NONE")

        let tools = await DeveloperToolsLocator.locate()
        guard let developerDir = tools.xcodeDeveloperDirectory else {
            print("ChangeMeHOLD FAIL missing Xcode")
            return 2
        }
        let discovery = DeviceDiscoveryService()
        let devices: [ConnectedDevice]
        do {
            devices = try await discovery.discoverDevices(tools: tools)
        } catch {
            print("ChangeMeHOLD FAIL discovery \(error)")
            return 3
        }
        guard let device = devices.first(where: { !$0.isSimulator && $0.isAvailable }) else {
            print("ChangeMeHOLD FAIL no physical iPhone")
            return 4
        }
        print("ChangeMeHOLD device=\(device.name) id=\(device.id)")

        let controller = PhysicalDeviceSessionController()
        do {
            try await controller.startSession(
                coordinate: target,
                deviceID: device.id,
                developerDirectory: developerDir
            )
        } catch {
            print("ChangeMeHOLD FAIL start \(error)")
            return 5
        }

        let startPID = await controller.xcodebuildPID
        print("ChangeMeHOLD START_OK pid=\(startPID ?? -1)")

        struct Row {
            var elapsed: Int
            var xctestAlive: Bool
            var tcpAlive: Bool
            var lat: Double?
            var lon: Double?
            var accuracy: Double?
            var matchesTarget: Bool
            var note: String
        }

        var rows: [Row] = []
        var firstMismatchElapsed: Int?
        var matchFlags: [Bool] = []
        let holdStarted = Date()

        // Immediate baseline sample (t≈0), then every 15s.
        while Date().timeIntervalSince(holdStarted) <= holdSeconds + 1 {
            let elapsed = Int(Date().timeIntervalSince(holdStarted))
            let sample = await controller.sampleCompanionLocation()
            let matches: Bool = {
                guard let lat = sample.latitude, let lon = sample.longitude else { return false }
                return abs(lat - target.latitude) < matchTolerance
                    && abs(lon - target.longitude) < matchTolerance
            }()
            matchFlags.append(matches)
            if !matches, firstMismatchElapsed == nil {
                firstMismatchElapsed = elapsed
            }
            let row = Row(
                elapsed: elapsed,
                xctestAlive: sample.xctestAlive,
                tcpAlive: sample.tcpAlive,
                lat: sample.latitude,
                lon: sample.longitude,
                accuracy: sample.horizontalAccuracy,
                matchesTarget: matches,
                note: sample.message ?? ""
            )
            rows.append(row)
            let latText = sample.latitude.map { String(format: "%.6f", $0) } ?? "nil"
            let lonText = sample.longitude.map { String(format: "%.6f", $0) } ?? "nil"
            let accText = sample.horizontalAccuracy.map { String(format: "%.0f", $0) } ?? "—"
            print(
                "ChangeMeHOLD SAMPLE t=\(elapsed)s xctest=\(sample.xctestAlive) tcp=\(sample.tcpAlive) lat=\(latText) lon=\(lonText) acc=\(accText) match=\(matches) \(sample.message ?? "")"
            )

            if !sample.xctestAlive || !sample.tcpAlive {
                print("ChangeMeHOLD SESSION_DIED t=\(elapsed)s")
                break
            }

            let next = holdStarted.addingTimeInterval(TimeInterval((rows.count) * Int(sampleInterval)))
            let sleepFor = next.timeIntervalSinceNow
            if sleepFor > 0, Date().timeIntervalSince(holdStarted) < holdSeconds {
                try? await Task.sleep(for: .seconds(sleepFor))
            } else if Date().timeIntervalSince(holdStarted) >= holdSeconds {
                break
            }
        }

        let stopResult = await controller.stopSession(sendStop: true, force: false)
        let orphan = await controller.ownedProcessIsRunning
        print("ChangeMeHOLD STOP result=\(stopResult) orphan=\(orphan)")

        // Classification A/B/C/D
        let allMatch = !matchFlags.isEmpty && matchFlags.allSatisfy { $0 }
        let anyMatch = matchFlags.contains(true)
        let sessionDied = rows.contains { !$0.xctestAlive || !$0.tcpAlive }
        let alternates: Bool = {
            guard matchFlags.count >= 4 else { return false }
            var flips = 0
            for i in 1..<matchFlags.count where matchFlags[i] != matchFlags[i - 1] {
                flips += 1
            }
            return flips >= 2
        }()

        let classification: String
        if sessionDied {
            classification = "C"
        } else if alternates {
            classification = "D"
        } else if allMatch {
            classification = "A"
        } else if anyMatch, let firstMismatchElapsed {
            classification = "B"
            print("ChangeMeHOLD LEFT_TARGET_AT t=\(firstMismatchElapsed)s")
        } else {
            classification = "B"
        }

        print("ChangeMeHOLD CLASSIFICATION=\(classification)")
        print("ChangeMeHOLD firstMismatch=\(firstMismatchElapsed.map(String.init) ?? "none")")
        print("ChangeMeHOLD samples=\(rows.count) allMatch=\(allMatch) sessionDied=\(sessionDied) alternates=\(alternates)")

        // Persist timeline for the report.
        let reportURL = URL(fileURLWithPath: "/tmp/changeme-hold-sample-norefresh.txt")
        var report = """
        ChangeMe HOLD SAMPLE (NO REFRESH)
        target=40.7580,-73.9855 Times Square
        interval=15s duration=600s
        classification=\(classification)
        firstMismatchElapsed=\(firstMismatchElapsed.map(String.init) ?? "none")
        samples=\(rows.count)

        elapsed\txctest\ttcp\tlat\tlon\tacc\tmatch\tnote
        """
        for row in rows {
            report += "\n\(row.elapsed)\t\(row.xctestAlive)\t\(row.tcpAlive)\t\(row.lat.map { String(format: "%.6f", $0) } ?? "nil")\t\(row.lon.map { String(format: "%.6f", $0) } ?? "nil")\t\(row.accuracy.map { String(format: "%.0f", $0) } ?? "—")\t\(row.matchesTarget)\t\(row.note)"
        }
        report += "\n"
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("ChangeMeHOLD REPORT \(reportURL.path)")
        print("ChangeMeHOLD DONE")
        return classification == "A" ? 0 : 20
    }

    /// Exercises the SAME readiness + LocationSimulationService.startSimulation path the GUI uses.
    @MainActor
    static func runGUIStartVerification() async -> Int32 {
        print("ChangeMeGUI_VERIFY begin")
        let tools = await DeveloperToolsLocator.locate()
        print("ChangeMeGUI_VERIFY hasXcode=\(tools.hasXcode) developerDir=\(tools.xcodeDeveloperDirectory?.path ?? "nil")")

        let service = LocationSimulationService(tools: tools)
        let discovery = DeviceDiscoveryService()
        let devices: [ConnectedDevice]
        do {
            devices = try await discovery.discoverDevices(tools: tools)
        } catch {
            print("ChangeMeGUI_VERIFY FAIL discovery \(error)")
            return 2
        }
        guard let device = devices.first(where: { !$0.isSimulator && $0.isAvailable }) else {
            print("ChangeMeGUI_VERIFY FAIL no physical iPhone")
            return 3
        }
        print("ChangeMeGUI_VERIFY device=\(device.name) id=\(device.id) developerMode=\(device.developerModeDisplay)")

        let profileHeuristic = PhysicalDeviceLocationRunner.hasUITestRunnerProfile()
        print("ChangeMeGUI_VERIFY profileHeuristic(diagnosticsOnly)=\(profileHeuristic)")

        let setupIssue = service.physicalSetupIssue(for: device)
        print("ChangeMeGUI_VERIFY physicalSetupIssue=\(setupIssue ?? "nil")")

        let coordinate = CLLocationCoordinate2D(latitude: 43.6426, longitude: -79.3871)
        let canStart =
            CoordinateValidation.isValid(coordinate)
            && setupIssue == nil
            && device.developerModeStatus?.lowercased() != "disabled"
        print("ChangeMeGUI_VERIFY canStartSimulation=\(canStart)")
        guard canStart else {
            print("ChangeMeGUI_VERIFY FAIL canStart still false")
            return 4
        }

        do {
            let outcome = try await service.startSimulation(device: device, coordinate: coordinate)
            guard outcome == .started else {
                print("ChangeMeGUI_VERIFY FAIL unexpected outcome \(outcome)")
                return 5
            }
            print("ChangeMeGUI_VERIFY START_OK")
            if let metrics = service.physicalSessionMetrics {
                print("ChangeMeGUI_VERIFY START_SECONDS=\(String(format: "%.1f", metrics.startupSeconds ?? -1))")
                print("ChangeMeGUI_VERIFY endpoint=\(service.physicalSessionEndpoint)")
            }
            try await service.stopSimulation()
            print("ChangeMeGUI_VERIFY STOP_OK result=\(String(describing: service.lastPhysicalStopResult))")
            print("ChangeMeGUI_VERIFY DONE")
            return 0
        } catch {
            print("ChangeMeGUI_VERIFY FAIL start/stop \(error)")
            await service.forceEndPhysicalSession()
            return 6
        }
    }
}

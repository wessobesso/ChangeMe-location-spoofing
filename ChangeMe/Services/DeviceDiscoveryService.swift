//
//  DeviceDiscoveryService.swift
//  ChangeMe
//

import Foundation

@MainActor
final class DeviceDiscoveryService {
    func discoverDevices(tools: DeveloperToolsStatus) async throws -> [ConnectedDevice] {
        guard let xcrun = tools.xcrunURL,
              let developerDir = tools.xcodeDeveloperDirectory
        else {
            throw AppError.xcodeToolsUnavailable(
                tools.diagnosticMessage
                    ?? "Install Xcode and ensure xcrun/devicectl are available."
            )
        }

        guard tools.hasDevicectl || tools.hasSimctl else {
            throw AppError.xcodeToolsUnavailable(
                tools.diagnosticMessage
                    ?? "Neither devicectl nor simctl is available."
            )
        }

        let env = ["DEVELOPER_DIR": developerDir.path]
        var devices: [ConnectedDevice] = []

        if tools.hasDevicectl {
            devices.append(contentsOf: try await discoverPhysicalDevices(xcrun: xcrun, environment: env))
        }

        if tools.hasSimctl {
            devices.append(contentsOf: await discoverBootedSimulators(xcrun: xcrun, environment: env))
        }

        return devices
            .filter(\.isCompatibleIPhone)
            .sorted { lhs, rhs in
                if lhs.isSimulator != rhs.isSimulator {
                    return !lhs.isSimulator && rhs.isSimulator
                }
                if lhs.isAvailable != rhs.isAvailable {
                    return lhs.isAvailable && !rhs.isAvailable
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func discoverPhysicalDevices(
        xcrun: URL,
        environment: [String: String]
    ) async throws -> [ConnectedDevice] {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("changeme-devices-\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let result = try await ProcessRunner.run(
            executable: xcrun,
            arguments: [
                "devicectl",
                "list",
                "devices",
                "--json-output",
                jsonURL.path
            ],
            environment: environment
        )

        guard result.succeeded else {
            throw AppError.commandExecutionFailed(
                result.combinedOutput.isEmpty
                    ? "devicectl list devices exited with \(result.exitCode)."
                    : result.combinedOutput
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw AppError.commandExecutionFailed(
                "Could not read device list JSON: \(error.localizedDescription)"
            )
        }

        return try parseDevices(from: data)
    }

    private func discoverBootedSimulators(
        xcrun: URL,
        environment: [String: String]
    ) async -> [ConnectedDevice] {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("changeme-sims-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: xcrun,
                arguments: ["simctl", "list", "devices", "booted", "-j"],
                environment: environment
            )
        } catch {
            return []
        }

        // simctl writes JSON to stdout when -j is used
        let data: Data
        if !result.stdout.isEmpty {
            data = Data(result.stdout.utf8)
        } else if let fileData = try? Data(contentsOf: jsonURL) {
            data = fileData
        } else {
            return []
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any]
        else {
            return []
        }

        var found: [ConnectedDevice] = []
        for (runtime, value) in devicesByRuntime {
            guard let list = value as? [[String: Any]] else { continue }
            for dict in list {
                guard let name = dict["name"] as? String,
                      let udid = dict["udid"] as? String,
                      let state = dict["state"] as? String,
                      state.lowercased() == "booted"
                else { continue }

                let isIPhone = name.lowercased().contains("iphone")
                guard isIPhone else { continue }

                let osVersion = runtime
                    .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.iOS-", with: "")
                    .replacingOccurrences(of: "-", with: ".")

                found.append(
                    ConnectedDevice(
                        id: udid,
                        name: "\(name) (Simulator)",
                        platform: "iOS Simulator",
                        connectionType: "Simulator",
                        productType: name,
                        osVersion: osVersion,
                        developerModeStatus: "enabled",
                        pairingState: "paired",
                        tunnelState: "connected",
                        ddiServicesAvailable: nil,
                        isSimulator: true,
                        isAvailable: true
                    )
                )
            }
        }
        return found
    }

    private func parseDevices(from data: Data) throws -> [ConnectedDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else {
            throw AppError.commandExecutionFailed("Unexpected JSON from devicectl list devices.")
        }

        return devices.compactMap { dict in
            parseDevice(dict)
        }
    }

    private func parseDevice(_ dict: [String: Any]) -> ConnectedDevice? {
        let identifier = (dict["identifier"] as? String) ?? ""
        let hardware = dict["hardwareProperties"] as? [String: Any] ?? [:]
        let deviceProps = dict["deviceProperties"] as? [String: Any] ?? [:]
        let connection = dict["connectionProperties"] as? [String: Any] ?? [:]

        let name = (deviceProps["name"] as? String)
            ?? (hardware["marketingName"] as? String)
            ?? "Unknown Device"

        let platform = (hardware["platform"] as? String) ?? "iOS"
        let productType = hardware["productType"] as? String
        let deviceType = hardware["deviceType"] as? String
        let reality = (hardware["reality"] as? String)?.lowercased()
        let osVersion = deviceProps["osVersionNumber"] as? String
        let developerMode = deviceProps["developerModeStatus"] as? String
        let transport = connection["transportType"] as? String
        let pairingState = (connection["pairingState"] as? String)?.lowercased()
        let tunnelState = (connection["tunnelState"] as? String)?.lowercased()

        let udid = (hardware["udid"] as? String) ?? identifier
        guard !udid.isEmpty else { return nil }

        let isSimulator = reality == "simulated" || (deviceType?.lowercased().contains("simulator") == true)
        let isAvailable =
            pairingState == "paired"
            || tunnelState == "connected"
            || (dict["connectionProperties"] != nil && !(pairingState == "unpaired"))

        // Prefer marking "available" based on state string when present.
        var available = isAvailable
        if let state = connectionStateHint(from: dict) {
            available = state
        }

        return ConnectedDevice(
            id: udid,
            name: name,
            platform: platform,
            connectionType: humanConnectionType(transport),
            productType: productType ?? deviceType,
            osVersion: osVersion,
            developerModeStatus: developerMode,
            pairingState: pairingState,
            tunnelState: tunnelState,
            ddiServicesAvailable: deviceProps["ddiServicesAvailable"] as? Bool,
            isSimulator: isSimulator,
            isAvailable: available
        )
    }

    private func connectionStateHint(from dict: [String: Any]) -> Bool? {
        // Human-readable listing sometimes embeds availability; JSON uses connectionProperties.
        if let deviceProps = dict["deviceProperties"] as? [String: Any],
           let ddi = deviceProps["ddiServicesAvailable"] as? Bool {
            // DDI availability is useful but not the only availability signal.
            _ = ddi
        }
        if let connection = dict["connectionProperties"] as? [String: Any] {
            if let pairing = connection["pairingState"] as? String {
                return pairing.lowercased() == "paired"
            }
        }
        return nil
    }

    private func humanConnectionType(_ transport: String?) -> String? {
        guard let transport else { return nil }
        switch transport.lowercased() {
        case "localnetwork":
            return "Network"
        case "wired", "usb":
            return "USB"
        default:
            return transport
        }
    }
}

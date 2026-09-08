//
//  DeveloperToolsLocator.swift
//  ChangeMe
//

import Foundation

struct DeveloperToolsStatus: Sendable {
    var xcodeDeveloperDirectory: URL?
    var xcrunURL: URL?
    var hasXcode: Bool
    var hasDevicectl: Bool
    var hasSimctl: Bool
    var hasDevicectlLocationSimulate: Bool
    var xcodeVersionString: String?
    var diagnosticMessage: String?

    var isReadyForDeviceDiscovery: Bool {
        hasXcode && (hasDevicectl || hasSimctl)
    }
}

enum DeveloperToolsLocator: Sendable {
    nonisolated private static var preferredDeveloperDir: URL {
        URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer",
            isDirectory: true
        )
    }

    nonisolated private static var systemXcrun: URL {
        URL(fileURLWithPath: "/usr/bin/xcrun")
    }

    static func locate() async -> DeveloperToolsStatus {
        await Task.detached(priority: .utility) {
            locateSync()
        }.value
    }

    nonisolated private static func locateSync() -> DeveloperToolsStatus {
        var status = DeveloperToolsStatus(
            xcodeDeveloperDirectory: nil,
            xcrunURL: nil,
            hasXcode: false,
            hasDevicectl: false,
            hasSimctl: false,
            hasDevicectlLocationSimulate: false,
            xcodeVersionString: nil,
            diagnosticMessage: nil
        )

        let developerDir = resolveDeveloperDirectory()
        status.xcodeDeveloperDirectory = developerDir

        guard let developerDir else {
            status.diagnosticMessage =
                "Xcode was not found. Install Xcode from the App Store, then open it once to finish setup."
            return status
        }

        status.hasXcode = true

        let env = ["DEVELOPER_DIR": developerDir.path]

        if let versionResult = try? ProcessRunner.runSyncPublic(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-version"],
            environment: env
        ), versionResult.succeeded {
            let firstLine = versionResult.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init)
            status.xcodeVersionString = firstLine
        }

        let xcrun = resolveXcrun(developerDir: developerDir)
        guard let xcrun else {
            status.diagnosticMessage = "xcrun is unavailable. Install Xcode or the Command Line Tools."
            return status
        }
        status.xcrunURL = xcrun

        if let help = try? ProcessRunner.runSyncPublic(
            executable: xcrun,
            arguments: ["devicectl", "--help"],
            environment: env
        ) {
            let output = help.combinedOutput.lowercased()
            if output.contains("core device") || output.contains("devicectl") || help.succeeded {
                status.hasDevicectl = true
            }
        }

        // Also accept a direct binary next to developer tools.
        let directDevicectl = developerDir.appendingPathComponent("usr/bin/devicectl")
        if FileManager.default.isExecutableFile(atPath: directDevicectl.path) {
            status.hasDevicectl = true
        }

        if let simHelp = try? ProcessRunner.runSyncPublic(
            executable: xcrun,
            arguments: ["simctl", "help", "location"],
            environment: env
        ), simHelp.combinedOutput.lowercased().contains("location") {
            status.hasSimctl = true
        }

        // Future Xcode builds may expose this. Probe without assuming success.
        if let simulateHelp = try? ProcessRunner.runSyncPublic(
            executable: xcrun,
            arguments: ["devicectl", "device", "simulate", "--help"],
            environment: env
        ) {
            let output = simulateHelp.combinedOutput.lowercased()
            let looksLikeUnexpected = output.contains("unexpected argument")
            if !looksLikeUnexpected && output.contains("location") {
                status.hasDevicectlLocationSimulate = true
            }
        }

        if !status.hasDevicectl && !status.hasSimctl {
            status.diagnosticMessage =
                "Xcode developer tools are required for device location simulation. Ensure the full Xcode app is installed and selected (xcode-select)."
        }

        return status
    }

    nonisolated private static func resolveXcrun(developerDir: URL) -> URL? {
        let fm = FileManager.default
        let candidates = [
            systemXcrun,
            developerDir.appendingPathComponent("usr/bin/xcrun"),
            URL(fileURLWithPath: "/usr/bin/xcrun")
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    nonisolated private static func resolveDeveloperDirectory() -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: preferredDeveloperDir.path) {
            return preferredDeveloperDir
        }

        let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
        if let result = try? ProcessRunner.runSyncPublic(
            executable: xcodeSelect,
            arguments: ["-p"],
            environment: nil
        ), result.succeeded {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty,
               fm.fileExists(atPath: path),
               path.contains("Xcode.app") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }

        return nil
    }
}

//
//  SessionOrphanStore.swift
//  ChangeMe
//
//  Remembers the last ChangeMe-owned physical session PID for cautious restart hints.
//  Never kills processes from stale PIDs alone (PIDs can be reused).
//

import Foundation

enum SessionOrphanStore {
    private static let defaultsKey = "ChangeMe.LastPhysicalSessionHint"

    struct Hint: Codable, Equatable {
        var pid: Int32
        var sessionIDPrefix: String
        var deviceID: String
        var startedAt: Date
    }

    static func save(pid: Int32, sessionToken: String, deviceID: String) {
        let hint = Hint(
            pid: pid,
            sessionIDPrefix: String(sessionToken.prefix(8)),
            deviceID: deviceID,
            startedAt: .now
        )
        if let data = try? JSONEncoder().encode(hint) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static func load() -> Hint? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Hint.self, from: data)
    }

    /// Returns a user-facing hint only when the recorded PID still exists AND still looks like xcodebuild.
    static func suspiciousPreviousSessionMessage() -> String? {
        guard let hint = load() else { return nil }
        // Ignore ancient hints.
        guard Date().timeIntervalSince(hint.startedAt) < 6 * 60 * 60 else {
            clear()
            return nil
        }
        guard processExists(pid: hint.pid), looksLikeXcodebuild(pid: hint.pid) else {
            clear()
            return nil
        }
        return "Previous developer session may still be active (pid \(hint.pid)). Use Clear Location if the iPhone still shows a simulated coordinate."
    }

    private static func processExists(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func looksLikeXcodebuild(pid: Int32) -> Bool {
        let path = "/bin/ps"
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let name = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return name.contains("xcodebuild")
    }
}

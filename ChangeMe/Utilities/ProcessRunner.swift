//
//  ProcessRunner.swift
//  ChangeMe
//

import Foundation

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    nonisolated var succeeded: Bool { exitCode == 0 }

    nonisolated var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum ProcessRunner: Sendable {
    /// Runs an executable with discrete arguments (never via a shell).
    nonisolated static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory
            )
        }.value
    }

    nonisolated private static func runSync(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppError.commandExecutionFailed(
                "Failed to launch \(executable.lastPathComponent): \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Synchronous helper for tool probing from detached contexts.
    nonisolated static func runSyncPublic(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> ProcessResult {
        try runSync(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: nil
        )
    }
}

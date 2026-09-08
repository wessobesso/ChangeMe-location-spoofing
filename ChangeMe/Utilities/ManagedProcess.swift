//
//  ManagedProcess.swift
//  ChangeMe
//
//  Long-lived Process wrapper that does not block the main actor.
//

import Foundation

final class ManagedProcess: @unchecked Sendable {
    private let process: Process
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var outputChunks: [String] = []
    private(set) var isRunning = false

    var processIdentifier: Int32 { process.processIdentifier }

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        self.process = process
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendOutput(text)
            // Do NOT fputs to the parent stdout/stderr. When ChangeMe is launched from
            // Xcode, forwarding xcodebuild's massive log can fill Xcode's console pipe
            // and deadlock the child while Start waits for "listening".
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendOutput(text)
        }

        try process.run()
        isRunning = true

        process.terminationHandler = { [weak self] _ in
            self?.isRunning = false
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func terminateGracefully() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { cont in
            if !process.isRunning {
                cont.resume(returning: process.terminationStatus)
                return
            }
            let existing = process.terminationHandler
            process.terminationHandler = { proc in
                existing?(proc)
                cont.resume(returning: proc.terminationStatus)
            }
        }
    }

    func combinedOutputSnapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return outputChunks.joined()
    }

    private func appendOutput(_ text: String) {
        lock.lock()
        outputChunks.append(text)
        if outputChunks.count > 500 {
            outputChunks.removeFirst(outputChunks.count - 500)
        }
        lock.unlock()
    }
}

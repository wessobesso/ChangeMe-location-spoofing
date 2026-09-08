//
//  LocationSessionClient.swift
//  ChangeMe
//
//  Mac-side TCP client that connects to the physical UITest listener over USB/LAN.
//  Intentionally NOT MainActor-isolated — socket I/O must not compete with SwiftUI/MapKit.
//

import Foundation
import Network

final class LocationSessionClient: @unchecked Sendable {
    private var connection: NWConnection?
    private var buffer = Data()
    private var inbox: [LocationSessionMessage.Envelope] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "changeme.mac.session.client")
    private(set) var isConnected = false

    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws {
        disconnect()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = OnceResume()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume {
                        cont.resume()
                    }
                case .failed(let error):
                    box.resume {
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    box.resume {
                        cont.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            self.receive(on: connection)

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume {
                    cont.resume(throwing: AppError.commandExecutionFailed(
                        "Timed out connecting to UITest listener at \(host):\(port)"
                    ))
                }
            }
        }
        isConnected = true
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        lock.lock()
        buffer = Data()
        inbox.removeAll()
        lock.unlock()
    }

    func send(_ envelope: LocationSessionMessage.Envelope) async throws {
        guard let connection else {
            throw AppError.commandExecutionFailed("Not connected to UITest session listener.")
        }
        let data = try LocationSessionMessage.encode(envelope)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func awaitMessage(types: Set<String>, timeout: TimeInterval) async -> LocationSessionMessage.Envelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let index = inbox.firstIndex(where: { types.contains($0.type) }) {
                let message = inbox.remove(at: index)
                lock.unlock()
                return message
            }
            lock.unlock()
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Stay off MainActor — drain on the Network queue path.
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                self.drainBufferLocked()
                self.lock.unlock()
            }
            if isComplete || error != nil {
                self.isConnected = false
                return
            }
            self.receive(on: connection)
        }
    }

    private func drainBufferLocked() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let envelope = LocationSessionMessage.decodeLine(line)
            else { continue }
            inbox.append(envelope)
        }
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

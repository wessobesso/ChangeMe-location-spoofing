//
//  LocationSessionClient.swift
//  ChangeMeDeviceUITests
//
//  TCP client used by the long-lived physical UITest to talk to ChangeMe on the Mac.
//

import Foundation
import Network

final class LocationSessionClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "changeme.session.client")
    private var connection: NWConnection?
    private var buffer = Data()
    private var inbox: [LocationSessionMessage.Envelope] = []
    private var waiters: [DispatchSemaphore] = []
    private let lock = NSLock()
    private(set) var isConnected = false

    init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    func connect(timeout: TimeInterval) throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection

        let connected = DispatchSemaphore(value: 0)
        var connectError: Error?

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
                connected.signal()
            case .failed(let error):
                connectError = error
                self?.isConnected = false
                connected.signal()
            case .cancelled:
                self?.isConnected = false
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveLoop()

        let waitResult = connected.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            connection.cancel()
            throw NSError(domain: "ChangeMeSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out connecting to ChangeMe at \(host):\(port)"
            ])
        }
        if let connectError {
            throw connectError
        }

        try send(.hello(token: token))
    }

    func send(_ envelope: LocationSessionMessage.Envelope) throws {
        guard let connection else {
            throw NSError(domain: "ChangeMeSession", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Not connected"
            ])
        }
        let data = try LocationSessionMessage.encode(envelope)
        let sent = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            sent.signal()
        })
        _ = sent.wait(timeout: .now() + 5)
        if let sendError { throw sendError }
    }

    func waitForMessage(types: Set<String> = [], timeout: TimeInterval) -> LocationSessionMessage.Envelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let index = inbox.firstIndex(where: { types.isEmpty || types.contains($0.type) }) {
                let message = inbox.remove(at: index)
                lock.unlock()
                return message
            }
            let semaphore = DispatchSemaphore(value: 0)
            waiters.append(semaphore)
            lock.unlock()

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = semaphore.wait(timeout: .now() + min(remaining, 1.0))
        }
        return nil
    }

    func cancel() {
        connection?.cancel()
        connection = nil
        isConnected = false
        lock.lock()
        waiters.forEach { $0.signal() }
        waiters.removeAll()
        lock.unlock()
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                self.isConnected = false
                self.lock.lock()
                self.waiters.forEach { $0.signal() }
                self.waiters.removeAll()
                self.lock.unlock()
                return
            }
            self.receiveLoop()
        }
    }

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            if newline < buffer.endIndex {
                buffer.removeSubrange(buffer.startIndex...newline)
            } else {
                buffer.removeAll()
            }
            guard let line = String(data: lineData, encoding: .utf8),
                  let envelope = LocationSessionMessage.decodeLine(line)
            else { continue }

            lock.lock()
            inbox.append(envelope)
            let waitersCopy = waiters
            waiters.removeAll()
            lock.unlock()
            waitersCopy.forEach { $0.signal() }
        }
    }
}

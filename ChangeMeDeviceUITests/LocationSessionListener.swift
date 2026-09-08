//
//  LocationSessionListener.swift
//  ChangeMeDeviceUITests
//
//  Device-side TCP listener. The Mac connects inbound over USB link-local.
//

import Foundation
import Network

final class LocationSessionListener: @unchecked Sendable {
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "changeme.session.listener")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var inbox: [LocationSessionMessage.Envelope] = []
    private var waiters: [DispatchSemaphore] = []
    private let lock = NSLock()
    private(set) var isReady = false

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start(timeout: TimeInterval) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        let started = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let error):
                startError = error
                started.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
        let result = started.wait(timeout: .now() + timeout)
        if result == .timedOut {
            throw NSError(domain: "ChangeMeSession", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Timed out starting device listener on \(port)"
            ])
        }
        if let startError { throw startError }
        isReady = true
        print("ChangeMeDIAG listening port=\(port)")
    }

    func send(_ envelope: LocationSessionMessage.Envelope) throws {
        guard let connection else {
            throw NSError(domain: "ChangeMeSession", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "No Mac client connected"
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

    func waitForClient(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connection != nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return connection != nil
    }

    func cancel() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        lock.lock()
        waiters.forEach { $0.signal() }
        waiters.removeAll()
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        buffer = Data()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.connection = nil
            }
            if case .cancelled = state {
                self?.connection = nil
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
        // Auth handshake from Mac may come as HELLO, or Mac may wait for device HELLO.
        print("ChangeMeDIAG mac_client_accepted")
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                self.connection = nil
                return
            }
            self.receive(on: connection)
        }
    }

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let envelope = LocationSessionMessage.decodeLine(line)
            else { continue }

            if let msgToken = envelope.token, !msgToken.isEmpty, msgToken != token,
               ["SET", "STOP", "PING", "HELLO", "SAMPLE"].contains(envelope.type) {
                try? send(.error("invalid token"))
                continue
            }

            lock.lock()
            inbox.append(envelope)
            let waitersCopy = waiters
            waiters.removeAll()
            lock.unlock()
            waitersCopy.forEach { $0.signal() }
        }
    }
}

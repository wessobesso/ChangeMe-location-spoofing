//
//  SimulationState.swift
//  ChangeMe
//

import Foundation

enum SimulationState: Equatable, Sendable {
    case idle
    case preparing
    case launchingTestRunner
    case waitingForConnection
    case applyingInitialLocation
    case active
    case updating
    case stopping
    case failed(String)
    case sessionLost
    case deviceDisconnected

    /// Back-compat aliases used by older call sites.
    static var inactive: SimulationState { .idle }
    static var starting: SimulationState { .preparing }

    var title: String {
        switch self {
        case .idle:
            return "No simulation"
        case .preparing, .launchingTestRunner, .waitingForConnection, .applyingInitialLocation:
            return "Starting Simulation…"
        case .active:
            return "Simulation Active"
        case .updating:
            return "Updating…"
        case .stopping:
            return "Stopping…"
        case .failed:
            return "Simulation Failed"
        case .sessionLost:
            return "Session Lost"
        case .deviceDisconnected:
            return "Device Disconnected"
        }
    }

    var stageDescription: String? {
        switch self {
        case .preparing:
            return "Preparing developer session…"
        case .launchingTestRunner:
            return "Starting developer session…"
        case .waitingForConnection:
            return "Connecting to iPhone…"
        case .applyingInitialLocation:
            return "Applying location…"
        case .stopping:
            return "Restoring real location…"
        case .updating:
            return "Updating location…"
        default:
            return nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .launchingTestRunner, .waitingForConnection,
             .applyingInitialLocation, .stopping, .updating:
            return true
        default:
            return false
        }
    }

    var isActive: Bool {
        switch self {
        case .active, .updating:
            return true
        default:
            return false
        }
    }

    var isStarting: Bool {
        switch self {
        case .preparing, .launchingTestRunner, .waitingForConnection, .applyingInitialLocation:
            return true
        default:
            return false
        }
    }

    var blocksDeviceSwitch: Bool {
        isActive || isBusy || self == .sessionLost
    }

    var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }

    func canTransition(to next: SimulationState) -> Bool {
        switch (self, next) {
        case (.idle, .preparing),
             (.idle, .failed),
             (.failed, .idle),
             (.failed, .preparing),
             (.sessionLost, .idle),
             (.sessionLost, .preparing),
             (.sessionLost, .stopping),
             (.deviceDisconnected, .idle),
             (.deviceDisconnected, .preparing),
             (.deviceDisconnected, .stopping),

             (.preparing, .launchingTestRunner),
             (.preparing, .failed),
             (.preparing, .idle),

             (.launchingTestRunner, .waitingForConnection),
             (.launchingTestRunner, .failed),
             (.launchingTestRunner, .idle),

             (.waitingForConnection, .applyingInitialLocation),
             (.waitingForConnection, .failed),
             (.waitingForConnection, .idle),

             (.applyingInitialLocation, .active),
             (.applyingInitialLocation, .failed),
             (.applyingInitialLocation, .idle),

             (.active, .updating),
             (.active, .stopping),
             (.active, .sessionLost),
             (.active, .deviceDisconnected),
             (.active, .failed),

             (.updating, .active),
             (.updating, .stopping),
             (.updating, .sessionLost),
             (.updating, .deviceDisconnected),
             (.updating, .failed),

             (.stopping, .idle),
             (.stopping, .failed),
             (.stopping, .sessionLost):
            return true

        default:
            // Allow same-state no-ops.
            return self == next
        }
    }
}

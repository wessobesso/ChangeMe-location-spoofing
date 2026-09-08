//
//  AppError.swift
//  ChangeMe
//

import Foundation

enum AppError: LocalizedError, Equatable {
    case noIPhoneConnected
    case deviceUnavailable(String)
    case developerModeUnavailable
    case xcodeToolsUnavailable(String)
    case invalidCoordinates
    case locationSearchFailed(String)
    case gpxCreationFailed(String)
    case simulationUnsupported(String)
    case simulationStartFailed(deviceName: String, details: String)
    case locationUpdateFailed(String)
    case commandExecutionFailed(String)
    case simulationStopFailed(String)
    case noDeviceSelected

    /// Short title suitable for an alert header.
    var alertTitle: String {
        switch self {
        case .simulationUnsupported:
            return "Location Simulation Unavailable"
        case .simulationStartFailed:
            return "Couldn’t Start Simulation"
        case .locationUpdateFailed:
            return "Location Update Failed"
        case .developerModeUnavailable:
            return "Developer Mode Required"
        case .xcodeToolsUnavailable:
            return "Xcode Tools Required"
        case .noDeviceSelected, .noIPhoneConnected, .deviceUnavailable:
            return "Device Unavailable"
        case .invalidCoordinates:
            return "Invalid Coordinates"
        case .locationSearchFailed:
            return "Search Failed"
        case .simulationStopFailed:
            return "Couldn’t Stop Simulation"
        default:
            return "Error"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noIPhoneConnected:
            return "No compatible iPhone detected."
        case .deviceUnavailable:
            return "The selected device is unavailable."
        case .developerModeUnavailable:
            return "Developer Mode is disabled on this iPhone. Enable it in Settings → Privacy & Security → Developer Mode."
        case .xcodeToolsUnavailable:
            return "Xcode developer tools are required for device location simulation."
        case .invalidCoordinates:
            return "Coordinates are invalid. Latitude must be -90…90 and longitude -180…180."
        case .locationSearchFailed:
            return "Location search failed."
        case .gpxCreationFailed:
            return "Could not create a GPX file."
        case .simulationUnsupported:
            return "Physical-device location simulation could not be started with the available Xcode interface."
        case .simulationStartFailed(let deviceName, _):
            return "The developer location session could not be started on \(deviceName)."
        case .locationUpdateFailed:
            return "The location could not be updated on the active developer session."
        case .commandExecutionFailed:
            return "A developer tool command failed."
        case .simulationStopFailed:
            return "Could not stop location simulation."
        case .noDeviceSelected:
            return "Select a connected iPhone before starting simulation."
        }
    }

    var technicalDetails: String? {
        switch self {
        case .deviceUnavailable(let detail),
             .xcodeToolsUnavailable(let detail),
             .locationSearchFailed(let detail),
             .gpxCreationFailed(let detail),
             .simulationUnsupported(let detail),
             .commandExecutionFailed(let detail),
             .simulationStopFailed(let detail),
             .locationUpdateFailed(let detail):
            return detail.isEmpty ? nil : detail
        case .simulationStartFailed(_, let details):
            return details.isEmpty ? nil : details
        default:
            return nil
        }
    }
}

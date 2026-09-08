//
//  ManualXcodeSession.swift
//  ChangeMe
//

import CoreLocation
import Foundation

/// Artifacts + instructions for the supported manual Xcode location workflow.
struct PreparedManualXcodeSession: Equatable, Sendable {
    let deviceName: String
    let latitude: Double
    let longitude: Double
    let gpxURL: URL
    let projectURL: URL
    let companionSchemeName: String

    var coordinateSummary: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    var steps: [String] {
        [
            "Open the ChangeMe Xcode project (ChangeMeDevice scheme).",
            "Select “\(deviceName)” as the run destination.",
            "Ensure an Apple ID is signed in (Xcode → Settings → Accounts) for automatic signing.",
            "Run ChangeMeDevice on the iPhone (▶️).",
            "Allow Location While Using App when prompted.",
            "In Xcode: Debug → Simulate Location → choose the prepared GPX (or Don’t Simulate Location first if a prior simulation is stuck).",
            "Confirm ChangeMeDevice shows approximately \(coordinateSummary).",
            "Optional: open Apple Maps / Weather on the phone and compare. Find My is not expected to change.",
            "To unlock CLI XCTest automation later: Product → Test once on this iPhone so Xcode creates the UITest runner profile."
        ]
    }
}

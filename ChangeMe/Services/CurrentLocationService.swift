//
//  CurrentLocationService.swift
//  ChangeMe
//

import AppKit
import CoreLocation
import Foundation

enum CurrentLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

@MainActor
final class CurrentLocationService: NSObject {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    private(set) var authorization: CurrentLocationAuthorization = .notDetermined
    private(set) var lastKnownLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        refreshAuthorization()
    }

    func refreshAuthorization() {
        if !CLLocationManager.locationServicesEnabled() {
            authorization = .unavailable
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            authorization = .notDetermined
        case .authorizedAlways, .authorized:
            authorization = .authorized
        case .denied:
            authorization = .denied
        case .restricted:
            authorization = .restricted
        @unknown default:
            authorization = .unavailable
        }
    }

    func requestAuthorizationIfNeeded() {
        refreshAuthorization()
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One-shot location request. Does not continuously track.
    func requestCurrentLocation() async throws -> CLLocation {
        refreshAuthorization()

        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(150))
                refreshAuthorization()
                if authorization != .notDetermined { break }
            }
        }

        guard authorization == .authorized else {
            throw AppError.locationSearchFailed(authorizationMessage)
        }

        if continuation != nil {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    var authorizationMessage: String {
        switch authorization {
        case .denied:
            return "Location permission is denied. Enable it in System Settings to use Current Location."
        case .restricted:
            return "Location access is restricted on this Mac."
        case .unavailable:
            return "Location services are unavailable."
        case .notDetermined:
            return "Location permission has not been granted yet."
        case .authorized:
            return ""
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension CurrentLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAuthorization()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.lastKnownLocation = location
            self.continuation?.resume(returning: location)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

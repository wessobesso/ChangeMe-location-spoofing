//
//  DeviceLocationSession.swift
//  ChangeMeDevice
//

import Combine
import CoreLocation
import Foundation

@MainActor
final class DeviceLocationSession: NSObject, ObservableObject {
    @Published var latitudeText = "—"
    @Published var longitudeText = "—"
    @Published var accuracyText = "—"
    @Published var statusText = "Starting…"
    @Published var errorText: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            statusText = "Requesting permission…"
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            statusText = "Receiving Core Location"
            manager.startUpdatingLocation()
        case .denied, .restricted:
            statusText = "Location permission denied"
            errorText = "Enable Location for ChangeMe Device in Settings."
        @unknown default:
            statusText = "Unknown authorization"
        }
    }

    private func apply(_ location: CLLocation) {
        latitudeText = String(format: "%.6f", location.coordinate.latitude)
        longitudeText = String(format: "%.6f", location.coordinate.longitude)
        if location.horizontalAccuracy >= 0 {
            accuracyText = String(format: "%.0f m", location.horizontalAccuracy)
        } else {
            accuracyText = "—"
        }
        statusText = "Receiving Core Location"
        errorText = nil
    }
}

extension DeviceLocationSession: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            apply(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            statusText = "Location error"
            errorText = error.localizedDescription
        }
    }
}

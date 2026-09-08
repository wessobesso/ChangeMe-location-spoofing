//
//  ContentView.swift
//  ChangeMeDevice
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var session: DeviceLocationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ChangeMe Device")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("appTitle")
                Text("Developer Location Session")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Connected developer location session")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sessionBanner")
            }

            Divider()

            Text("Current Location")
                .font(.headline)

            labeled(title: "Latitude", value: session.latitudeText, id: "latitude")
            labeled(title: "Longitude", value: session.longitudeText, id: "longitude")
            labeled(title: "Accuracy", value: session.accuracyText, id: "accuracy")
            labeled(title: "Source/status", value: session.statusText, id: "status")

            if let error = session.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("locationError")
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { session.start() }
    }

    private func labeled(title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier(id)
                .accessibilityValue(value)
        }
    }
}

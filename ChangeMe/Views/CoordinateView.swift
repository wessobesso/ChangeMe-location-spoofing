//
//  CoordinateView.swift
//  ChangeMe
//

import SwiftUI

struct CoordinateView: View {
    @Bindable var viewModel: LocationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCATION")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                let lines = viewModel.selectedLocation.formattedAddressLines
                if let title = lines.first {
                    Text(title)
                        .font(.headline)
                        .textSelection(.enabled)
                }

                ForEach(Array(lines.dropFirst()), id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if viewModel.isResolvingPlace {
                    Text(viewModel.placeResolutionMessage ?? "Finding location…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(viewModel.selectedLocation.coordinateString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }

            if let message = viewModel.currentLocationStatusMessage, !message.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Current Location unavailable", systemImage: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Open Location Settings") {
                        viewModel.openLocationSettings()
                    }
                    .font(.caption)
                }
            }

            DisclosureGroup("Coordinates") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Latitude")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Latitude", text: $viewModel.latitudeText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { viewModel.applyLatitudeLongitudeFields() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Longitude")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Longitude", text: $viewModel.longitudeText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { viewModel.applyLatitudeLongitudeFields() }
                    }

                    HStack {
                        Button("Apply") {
                            viewModel.applyLatitudeLongitudeFields()
                        }
                        Button("Copy") {
                            viewModel.copyCoordinates()
                        }
                    }
                }
                .padding(.top, 4)
            }

            Button {
                viewModel.saveFavorite()
            } label: {
                Label("Save Location", systemImage: "star")
            }
        }
    }
}

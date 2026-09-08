//
//  DevicePanelView.swift
//  ChangeMe
//

import SwiftUI

struct DevicePanelView: View {
    @Bindable var viewModel: LocationViewModel
    @State private var hoveredRecentID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                deviceSection
                CoordinateView(viewModel: viewModel)
                simulationSection
                StatusView(viewModel: viewModel)
                recentSection
                favoritesSection
                helpSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("DEVICE")

            if viewModel.devices.isEmpty {
                Text("No iPhone connected")
                    .foregroundStyle(.primary)
                Text("Connect an iPhone by USB to start a physical developer location session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Connected Device", selection: $viewModel.selectedDeviceID) {
                    ForEach(viewModel.devices) { device in
                        Text(deviceLabel(device))
                            .tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .disabled(!viewModel.canChangeSelectedDevice)

                if let device = viewModel.selectedDevice {
                    Text(device.displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.canChangeSelectedDevice {
                    Text("Stop simulation before switching devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await viewModel.refreshDevices() }
            } label: {
                Label(
                    viewModel.isRefreshingDevices ? "Refreshing…" : "Refresh Devices",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(viewModel.isRefreshingDevices)
        }
    }

    private var simulationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SIMULATION")

            if viewModel.simulationState.isStarting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.simulationState.title)
                        if let stage = viewModel.simulationState.stageDescription {
                            Text(stage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Button {
                    Task { await viewModel.startSimulation() }
                } label: {
                    Text(viewModel.startSimulationButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canStartSimulation)
                .help(viewModel.startSimulationDisabledReason ?? viewModel.startSimulationButtonTitle)
            }

            if viewModel.isDeveloperModeDisabled {
                Text("Developer Mode is off. Enable it in Settings → Privacy & Security → Developer Mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = viewModel.startSimulationDisabledReason,
                      !viewModel.canStartSimulation,
                      !viewModel.simulationState.isActive,
                      !viewModel.simulationState.isStarting {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let orphan = viewModel.orphanSessionHint, viewModel.simulationState == .idle {
                Text(orphan)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await viewModel.clearLocationAfterSessionLoss() }
                } label: {
                    Text("Clear Location")
                        .frame(maxWidth: .infinity)
                }
            }

            Button {
                Task { await viewModel.stopSimulation() }
            } label: {
                Text(viewModel.simulationState == .stopping ? "Stopping…" : "Stop Simulation")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!viewModel.canStopSimulation || (viewModel.simulationState.isBusy && viewModel.simulationState != .updating))

            if viewModel.simulationState == .sessionLost || viewModel.simulationState == .deviceDisconnected || viewModel.showForceEndControls {
                if viewModel.simulationState == .deviceDisconnected {
                    Text("iPhone disconnected. Simulation session may no longer be active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await viewModel.startSimulation() }
                    } label: {
                        Text("Restart Simulation")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!viewModel.canStartSimulation)
                }

                if viewModel.showForceEndControls || viewModel.simulationState == .sessionLost {
                    Text("The developer session could not confirm that the simulated location was cleared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Task { await viewModel.forceEndSession() }
                    } label: {
                        Text("Force End Session")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }

                Button {
                    Task { await viewModel.clearLocationAfterSessionLoss() }
                } label: {
                    Text("Clear Location")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("RECENT")
                Spacer()
                if !viewModel.recentLocations.isEmpty {
                    Button("Clear") {
                        viewModel.clearRecentLocations()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if viewModel.recentLocations.isEmpty {
                Text("No recent locations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recentLocations.prefix(5)) { location in
                    Button {
                        viewModel.selectStoredLocation(location)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.displayName)
                                .lineLimit(1)
                            Text(location.secondaryLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(hoveredRecentID == location.id ? Color.primary.opacity(0.06) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredRecentID = hovering ? location.id : nil
                    }
                }
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("FAVORITES")

            if viewModel.favoriteLocations.isEmpty {
                Text("No saved locations yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.favoriteLocations) { location in
                    HStack(alignment: .top) {
                        Button {
                            viewModel.selectStoredLocation(location)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.displayName)
                                    .lineLimit(1)
                                Text(location.secondaryLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            viewModel.removeFavorite(location)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove favorite")
                    }
                }
            }
        }
    }

    private var helpSection: some View {
        DisclosureGroup("SETUP HELP") {
            VStack(alignment: .leading, spacing: 8) {
                Text("iPhone setup")
                    .fontWeight(.semibold)
                Text("1. Connect your iPhone by USB.")
                Text("2. Trust this Mac when prompted.")
                Text("3. Enable Developer Mode: Settings → Privacy & Security → Developer Mode.")
                Text("4. First-time only: in Xcode, open ChangeMe → ChangeMeDevice → your iPhone → Product → Test once.")

                Divider()

                Text("Normal use")
                    .fontWeight(.semibold)
                Text("Select a place on the map, click Start Simulation, wait ~20 seconds, then change locations from ChangeMe. Stop restores the real location.")
                Text("Keep the iPhone connected by USB. Wi‑Fi is not required.")

                Divider()

                Text("Scope")
                    .fontWeight(.semibold)
                Text("ChangeMe controls Apple’s developer simulated location API only.")
                Text("Some system location consumers may reflect the developer-simulated location while the test session is active. This behavior is not guaranteed by Apple.")

                DisclosureGroup("Diagnostics") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.diagnosticsLines.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.0)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(row.1)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func deviceLabel(_ device: ConnectedDevice) -> String {
        var label = device.name
        if !device.isAvailable {
            label += " (unavailable)"
        }
        return label
    }
}

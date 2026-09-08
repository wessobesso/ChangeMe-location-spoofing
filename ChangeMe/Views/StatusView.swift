//
//  StatusView.swift
//  ChangeMe
//

import SwiftUI

struct StatusView: View {
    @Bindable var viewModel: LocationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STATUS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(viewModel.simulationState.title)
                            .fontWeight(.medium)
                        if viewModel.simulationState.isBusy {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    Text(statusDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if case .failed(let message) = viewModel.simulationState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            if let warning = viewModel.toolsWarning {
                Label(warning, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusDetailText: String {
        switch viewModel.simulationState {
        case .active, .updating:
            if let detail = viewModel.statusDetail { return detail }
            return "\(viewModel.selectedLocation.displayName)\n\(viewModel.selectedLocation.coordinateString)"
        case .preparing, .launchingTestRunner, .waitingForConnection, .applyingInitialLocation, .stopping:
            return viewModel.statusDetail
                ?? viewModel.simulationState.stageDescription
                ?? viewModel.simulationState.title
        case .sessionLost, .deviceDisconnected:
            return viewModel.statusDetail
                ?? "Simulation session may no longer be active."
        default:
            break
        }

        if let detail = viewModel.statusDetail,
           detail.hasPrefix("Selected:") || detail.hasPrefix("Ready:") || detail.hasPrefix("Copied")
            || detail.hasPrefix("Simulation stopped") || detail.hasPrefix("Connect an iPhone")
            || detail.hasPrefix("Saved") || detail.hasPrefix("Location cleared")
            || detail.hasPrefix("iPhone Reconnected") {
            return detail
        }

        return "Ready: \(viewModel.selectedLocation.displayName)"
    }

    private var statusColor: Color {
        switch viewModel.simulationState {
        case .idle:
            return .secondary
        case .preparing, .launchingTestRunner, .waitingForConnection, .applyingInitialLocation, .stopping, .updating:
            return .orange
        case .active:
            return .green
        case .sessionLost, .deviceDisconnected:
            return .orange
        case .failed:
            return .red
        }
    }
}

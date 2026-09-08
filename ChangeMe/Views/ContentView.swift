//
//  ContentView.swift
//  ChangeMe
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = LocationViewModel()

    var body: some View {
        HSplitView {
            MapView(viewModel: viewModel)
                .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)

            DevicePanelView(viewModel: viewModel)
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            ChangeMeAppDelegate.shared?.viewModel = viewModel
            viewModel.onAppear()
        }
        .task {
            // Ensure the app delegate can always reach the live GUI view model.
            ChangeMeAppDelegate.shared?.viewModel = viewModel
        }
        .alert(viewModel.errorAlertTitle, isPresented: $viewModel.showErrorAlert) {
            if viewModel.errorTechnicalDetails != nil {
                Button("Details") {
                    viewModel.showErrorDetailsSheet = true
                }
            }
            if case .locationUpdateFailed = viewModel.lastError {
                Button("Retry") {
                    viewModel.scheduleRetryUpdate()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorAlertMessage)
        }
        .alert("Simulation is active", isPresented: $viewModel.showQuitWhileActiveAlert) {
            Button("Stop & Quit") {
                viewModel.confirmStopAndQuit()
            }
            Button("Quit Without Stopping", role: .destructive) {
                viewModel.quitWithoutStopping()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelQuit()
            }
        } message: {
            Text("Stop simulation and restore the iPhone’s location before quitting?")
        }
        .sheet(isPresented: $viewModel.showErrorDetailsSheet) {
            NavigationStack {
                ScrollView {
                    Text(viewModel.errorTechnicalDetails ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Details")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            viewModel.showErrorDetailsSheet = false
                        }
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 320)
        }
        .sheet(isPresented: $viewModel.showManualXcodeSheet) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Physical-device location simulation could not start automatically. ChangeMe prepared a GPX for your selected coordinate.")
                            .fixedSize(horizontal: false, vertical: true)

                        if let session = viewModel.preparedManualSession {
                            Text("Coordinate: \(session.coordinateSummary)")
                                .font(.system(.body, design: .monospaced))
                            Text("GPX: \(session.gpxURL.path)")
                                .font(.caption)
                                .textSelection(.enabled)

                            ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                                Text("\(index + 1). \(step)")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle("Setup Required")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            viewModel.showManualXcodeSheet = false
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open Xcode Project") {
                            viewModel.openPreparedXcodeProject()
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button("Reveal GPX") {
                            viewModel.revealPreparedGPX()
                        }
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 420)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1100, height: 750)
}

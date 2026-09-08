//
//  LocationSimulatorApp.swift
//  ChangeMe
//

import AppKit
import CoreLocation
import SwiftUI

@main
struct LocationSimulatorApp: App {
    @NSApplicationDelegateAdaptor(ChangeMeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class ChangeMeAppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: ChangeMeAppDelegate?
    weak var viewModel: LocationViewModel?

    override init() {
        super.init()
        // Available before applicationDidFinishLaunching so ContentView can publish early.
        ChangeMeAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ChangeMeAppDelegate.shared = self
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--acceptance-physical") {
            Task {
                let code = await PhysicalSessionAcceptance.run()
                if code != 0 {
                    exit(code)
                }
                NSApp.terminate(nil)
            }
            return
        }
        if args.contains("--hold-sample-physical") {
            Task {
                let code = await PhysicalSessionAcceptance.runHoldSampleNoRefresh()
                exit(code)
            }
            return
        }
        if args.contains("--verify-gui-start") {
            Task {
                let code = await PhysicalSessionAcceptance.runGUIStartVerification()
                exit(code)
            }
        }
        if args.contains("--debug-gui-button-start-cn") {
            Task { @MainActor in
                func dbg(_ message: String) {
                    let line = message + "\n"
                    fputs(line, stderr)
                    if let handle = FileHandle(forWritingAtPath: "/tmp/changeme-debug.log") {
                        handle.seekToEndOfFile()
                        handle.write(Data(line.utf8))
                        try? handle.close()
                    } else {
                        FileManager.default.createFile(atPath: "/tmp/changeme-debug.log", contents: Data(line.utf8))
                    }
                }

                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                for _ in 0..<200 {
                    NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
                    if ChangeMeAppDelegate.shared?.viewModel != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let viewModel = ChangeMeAppDelegate.shared?.viewModel else {
                    dbg("ChangeMeDEBUG no viewModel")
                    exit(9)
                }
                try? await Task.sleep(for: .seconds(4))
                viewModel.applySelectedLocation(
                    MapLocation(
                        name: "CN Tower",
                        subtitle: "Toronto, ON",
                        coordinate: CLLocationCoordinate2D(latitude: 43.6426, longitude: -79.3871)
                    ),
                    centerMap: true,
                    recordRecent: false,
                    fromUserEdit: true
                )
                dbg("ChangeMeDEBUG invoking viewModel.startSimulation() (GUI button path)")
                let began = Date()
                await viewModel.startSimulation()
                let elapsed = Date().timeIntervalSince(began)
                dbg("ChangeMeDEBUG startSimulation returned state=\(viewModel.simulationState) elapsed=\(String(format: "%.1f", elapsed))s")
                guard viewModel.simulationState == .active else {
                    exit(10)
                }

                // Same-session update (Times Square) via the live GUI view model path.
                let updateBegan = Date()
                do {
                    try await viewModel.debugUpdateSimulation(
                        coordinate: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)
                    )
                    let updateElapsed = Date().timeIntervalSince(updateBegan)
                    dbg("ChangeMeDEBUG UPDATE_OK elapsed=\(String(format: "%.1f", updateElapsed))s")
                } catch {
                    dbg("ChangeMeDEBUG UPDATE_FAIL \(error)")
                }

                let stopBegan = Date()
                await viewModel.stopSimulation()
                let stopElapsed = Date().timeIntervalSince(stopBegan)
                let orphan = viewModel.debugOwnedProcessRunning
                dbg("ChangeMeDEBUG STOP state=\(viewModel.simulationState) elapsed=\(String(format: "%.1f", stopElapsed))s orphan=\(orphan)")
                exit(viewModel.simulationState == .idle && !orphan ? 0 : 11)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else {
            return .terminateNow
        }
        if viewModel.simulationState.isActive
            || viewModel.simulationState.isStarting
            || viewModel.simulationState == .updating {
            Task { @MainActor in
                let shouldQuit = await viewModel.prepareForAppTermination()
                NSApp.reply(toApplicationShouldTerminate: shouldQuit)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

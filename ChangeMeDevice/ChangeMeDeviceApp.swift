//
//  ChangeMeDeviceApp.swift
//  ChangeMeDevice
//

import SwiftUI

@main
struct ChangeMeDeviceApp: App {
    @StateObject private var session = DeviceLocationSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
    }
}

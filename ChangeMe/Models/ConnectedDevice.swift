//
//  ConnectedDevice.swift
//  ChangeMe
//

import Foundation

struct ConnectedDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let platform: String
    let connectionType: String?
    let productType: String?
    let osVersion: String?
    let developerModeStatus: String?
    let pairingState: String?
    let tunnelState: String?
    let ddiServicesAvailable: Bool?
    let isSimulator: Bool
    let isAvailable: Bool

    var displaySubtitle: String {
        var parts: [String] = [platform]
        if let osVersion, !osVersion.isEmpty {
            parts.append(osVersion)
        }
        if let connectionType, !connectionType.isEmpty {
            parts.append(connectionType)
        }
        return parts.joined(separator: " · ")
    }

    var developerModeDisplay: String {
        guard let developerModeStatus, !developerModeStatus.isEmpty else {
            return isSimulator ? "N/A (Simulator)" : "Unknown"
        }
        switch developerModeStatus.lowercased() {
        case "enabled":
            return "Enabled"
        case "disabled":
            return "Disabled"
        default:
            return developerModeStatus.capitalized
        }
    }

    var isCompatibleIPhone: Bool {
        let platformLower = platform.lowercased()
        let productLower = (productType ?? "").lowercased()
        let nameLower = name.lowercased()

        let looksLikePhone =
            platformLower.contains("ios")
            || productLower.contains("iphone")
            || nameLower.contains("iphone")

        let looksLikePad =
            productLower.contains("ipad")
            || nameLower.contains("ipad")
            || platformLower.contains("ipados")

        return looksLikePhone && !looksLikePad
    }
}

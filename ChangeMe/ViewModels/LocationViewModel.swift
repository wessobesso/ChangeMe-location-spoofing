//
//  LocationViewModel.swift
//  ChangeMe
//

import AppKit
import CoreLocation
import Foundation
import MapKit
import SwiftUI

@Observable
@MainActor
final class LocationViewModel {
    // Separate concepts
    var currentLocation: MapLocation?
    var selectedLocation = MapLocation.worldFallback

    var selectedCoordinate: CLLocationCoordinate2D { selectedLocation.coordinate }
    var selectedName: String? { selectedLocation.name }
    var selectedSubtitle: String? { selectedLocation.subtitle }

    var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: MapLocation.worldFallback.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 80)
        )
    )
    /// When false, map region updates from the view model won't override user panning.
    var cameraFollowEnabled = true

    var latitudeText = ""
    var longitudeText = ""

    var isResolvingPlace = false
    var placeResolutionMessage: String?
    var currentLocationStatusMessage: String?
    var isLocating = false

    // Search
    var searchQuery = ""
    var searchSuggestions: [LocationSearchSuggestion] = []
    var highlightedSuggestionIndex: Int = -1
    var isSearchPanelVisible = false
    var isSearching = false
    /// True while resolving a selected completion / Return search.
    var isResolvingSearch = false
    /// When true, completer callbacks and query observers must not reopen the panel.
    private var suppressSearchCompletions = false
    /// True while the app (not the user) is assigning `searchQuery`.
    private var isProgrammaticSearchQueryUpdate = false
    /// Drives @FocusState in SearchBarView without coupling search text to selected place.
    var wantsSearchFocus = false

    var shouldShowSearchSuggestions: Bool {
        wantsSearchFocus
            && !suppressSearchCompletions
            && !isResolvingSearch
            && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !searchSuggestions.isEmpty
    }

    // Devices
    var devices: [ConnectedDevice] = []
    var selectedDeviceID: String?
    var isRefreshingDevices = false

    // Simulation
    var simulationState: SimulationState = .idle
    var statusDetail: String?
    var lastError: AppError?
    var showErrorAlert = false
    var errorAlertTitle = "Error"
    var errorAlertMessage = ""
    var errorTechnicalDetails: String?
    var showErrorDetailsSheet = false
    var showForceEndControls = false
    var orphanSessionHint: String?
    var showQuitWhileActiveAlert = false
    var pendingQuitContinuation: CheckedContinuation<Bool, Never>?

    var preparedManualSession: PreparedManualXcodeSession?
    var showManualXcodeSheet = false

    // Persistence (recents/favorites store)
    var recentLocations: [MapLocation] = []
    var favoriteLocations: [MapLocation] = []

    // Tools
    var toolsStatus = DeveloperToolsStatus(
        xcodeDeveloperDirectory: nil,
        xcrunURL: nil,
        hasXcode: false,
        hasDevicectl: false,
        hasSimctl: false,
        hasDevicectlLocationSimulate: false,
        xcodeVersionString: nil,
        diagnosticMessage: nil
    )

    var visibleMapRegion: MKCoordinateRegion?

    private let searchService = LocationSearchService()
    private let currentLocationService = CurrentLocationService()
    private let deviceService = DeviceDiscoveryService()
    private let simulationService = LocationSimulationService()
    private let store = LocationStore()

    private var updateDebounceTask: Task<Void, Never>?
    private var updateSerialTask: Task<Void, Never>?
    private var pendingUpdateCoordinate: CLLocationCoordinate2D?
    private var searchSuggestTask: Task<Void, Never>?
    private var reverseLookupTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var reverseGeneration = 0

    var selectedDevice: ConnectedDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isDeveloperModeDisabled: Bool {
        guard let device = selectedDevice, !device.isSimulator else { return false }
        return device.developerModeStatus?.lowercased() == "disabled"
    }

    var startSimulationButtonTitle: String {
        guard let device = selectedDevice else { return "Start Simulation" }
        if device.isSimulator { return "Start Simulation" }
        let capability = simulationService.capability(for: device)
        return capability.usesAutomaticStart ? "Start Simulation" : "Start via Xcode"
    }

    var canStartSimulation: Bool {
        selectedDevice != nil
            && CoordinateValidation.isValid(selectedCoordinate)
            && simulationState == .idle
            && !isDeveloperModeDisabled
            && physicalSetupIssue == nil
    }

    var physicalSetupIssue: String? {
        guard let device = selectedDevice, !device.isSimulator else { return nil }
        return simulationService.physicalSetupIssue(for: device)
    }

    var startSimulationDisabledReason: String? {
        if selectedDevice == nil {
            return "Connect an iPhone by USB to start a physical developer location session."
        }
        if isDeveloperModeDisabled {
            return "Enable Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode)."
        }
        if let issue = physicalSetupIssue { return issue }
        if !CoordinateValidation.isValid(selectedCoordinate) { return "Coordinates are invalid." }
        if simulationState.isActive { return "Simulation is already active." }
        if simulationState.isBusy { return nil }
        if simulationState != .idle { return "Finish or clear the current session first." }
        return nil
    }

    var canChangeSelectedDevice: Bool {
        !simulationState.blocksDeviceSwitch
    }

    var toolsWarning: String? {
        if !toolsStatus.isReadyForDeviceDiscovery {
            return toolsStatus.diagnosticMessage
                ?? "Xcode developer tools are required for device location simulation."
        }
        return nil
    }

    var lastGeneratedGPXPath: String? {
        simulationService.lastGPXURL?.path
    }

    var simulationBackendSummary: String {
        if let device = selectedDevice {
            return simulationService.capability(for: device).summary
        }
        return "No device selected"
    }

    var xcodeVersionSummary: String {
        if toolsStatus.xcodeDeveloperDirectory == nil {
            return "Not found"
        }
        return toolsStatus.hasXcode ? "Installed at \(toolsStatus.xcodeDeveloperDirectory!.path)" : "Not found"
    }

    var diagnosticsLines: [(String, String)] {
        var lines: [(String, String)] = []
        if let device = selectedDevice {
            lines.append(("Device", device.name))
            lines.append(("Connection", device.connectionType ?? "Unknown"))
            lines.append(("iOS", device.osVersion ?? "Unknown"))
            lines.append(("Paired", device.pairingState ?? "Unknown"))
            lines.append(("Tunnel", device.tunnelState ?? "Unknown"))
            lines.append(("Developer Mode", device.developerModeDisplay))
            if let ddi = device.ddiServicesAvailable {
                lines.append(("DDI services", ddi ? "Available" : "Unavailable"))
            }
            lines.append(("Device identifier", device.id))
        } else {
            lines.append(("Device", "None selected"))
        }
        lines.append(("Xcode", toolsStatus.xcodeVersionString ?? (toolsStatus.hasXcode ? "Found" : "Missing")))
        if let dir = toolsStatus.xcodeDeveloperDirectory {
            lines.append(("DEVELOPER_DIR", dir.path))
        }
        lines.append(("devicectl", toolsStatus.hasDevicectl ? "Available" : "Missing"))
        lines.append(("simctl location", toolsStatus.hasSimctl ? "Available" : "Missing"))
        lines.append((
            "devicectl location CLI",
            toolsStatus.hasDevicectlLocationSimulate ? "Available" : "Not present (Xcode 26.6)"
        ))
        lines.append(("Simulation backend", simulationBackendSummary))
        lines.append(("Companion target", "ChangeMeDevice (iOS)"))
        lines.append(("XCUILocation API", "Physical XCTest proven (XCUIDevice.location)"))
        lines.append((
            "UITest runner profile",
            "Not consulted at Start (xcodebuild is authoritative)"
        ))
        lines.append((
            "System location note",
            "Some system location consumers may reflect the developer-simulated location while the test session is active. This behavior is not guaranteed by Apple."
        ))
        lines.append(("Physical session", "Long-lived XCTest; Mac → iPhone USB link-local TCP"))
        lines.append(("Session endpoint", simulationService.physicalSessionEndpoint))
        lines.append((
            "Session authentication",
            simulationService.physicalSessionAuthenticationActive ? "active" : "inactive"
        ))
        if let metrics = simulationService.physicalSessionMetrics {
            lines.append(("Runner connected", metrics.runnerConnected ? "yes" : "no"))
            if let at = metrics.lastCommandAppliedAt {
                lines.append(("Last command applied", at.formatted(date: .omitted, time: .standard)))
            }
            if let verified = metrics.lastVerifiedCoordinate, let at = metrics.lastVerifiedAt {
                lines.append((
                    "Last verified coordinate",
                    String(
                        format: "%.4f, %.4f (%@)",
                        verified.latitude,
                        verified.longitude,
                        at.formatted(date: .omitted, time: .standard)
                    )
                ))
            }
            if let lat = metrics.lastSampleLatitude, let lon = metrics.lastSampleLongitude {
                let acc = metrics.lastSampleHorizontalAccuracy.map { String(format: "%.0fm", $0) } ?? "—"
                lines.append(("Last companion sample", String(format: "%.5f, %.5f (±%@)", lat, lon, acc)))
            }
            lines.append(("Companion samples", "\(metrics.sampleCount)"))
        }
        if let pid = simulationService.activeXcodebuildPID {
            lines.append(("Owned runner PID", "\(pid)"))
        }
        if let metrics = simulationService.physicalSessionMetrics {
            if let s = metrics.startupSeconds {
                lines.append(("Last Start", String(format: "%.1fs", s)))
            }
            if let s = metrics.runnerLaunchSeconds {
                lines.append(("Runner launch", String(format: "%.1fs", s)))
            }
            if let s = metrics.connectionSeconds {
                lines.append(("USB connection", String(format: "%.1fs", s)))
            }
            if let s = metrics.lastUpdateSeconds {
                lines.append(("Last Update", String(format: "%.1fs", s)))
            }
            if let s = metrics.stopSeconds {
                lines.append(("Last Stop", String(format: "%.1fs", s)))
            }
            if let duration = metrics.sessionDurationSeconds {
                lines.append(("Session duration", Self.formatDuration(duration)))
            }
        }
        if let run = simulationService.lastPhysicalRun {
            lines.append(("Last one-shot clear", run.succeeded ? "Succeeded" : "Failed"))
            lines.append(("Last clear duration", String(format: "%.1fs", run.durationSeconds)))
        }
        if let orphanSessionHint {
            lines.append(("Orphan hint", orphanSessionHint))
        }
        if let gpx = lastGeneratedGPXPath {
            lines.append(("Last GPX (optional)", gpx))
        }
        return lines
    }

    var isCurrentLocationUnavailable: Bool {
        switch currentLocationService.authorization {
        case .denied, .restricted, .unavailable:
            return true
        default:
            return currentLocation == nil && currentLocationStatusMessage != nil
        }
    }

    var showsCurrentLocationMarker: Bool {
        guard let current = currentLocation else { return false }
        let selected = CLLocation(
            latitude: selectedCoordinate.latitude,
            longitude: selectedCoordinate.longitude
        )
        let actual = CLLocation(
            latitude: current.latitude,
            longitude: current.longitude
        )
        return actual.distance(from: selected) > 20
    }

    init() {
        syncCoordinateFields()
        searchService.onSuggestions { [weak self] suggestions in
            guard let self else { return }
            // Ignore late completer results after a selection / programmatic query update.
            guard !self.suppressSearchCompletions, !self.isResolvingSearch else { return }
            guard self.wantsSearchFocus else { return }

            let limited = Array(suggestions.prefix(6))
            self.searchSuggestions = limited
            self.isSearchPanelVisible = !limited.isEmpty
                && !self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if self.highlightedSuggestionIndex >= limited.count {
                self.highlightedSuggestionIndex = -1
            }
        }
        recentLocations = store.loadRecent()
        favoriteLocations = store.loadFavorites()
    }

    func onAppear() {
        orphanSessionHint = SessionOrphanStore.suspiciousPreviousSessionMessage()
        simulationService.onPhysicalSessionLost = { [weak self] in
            guard let self else { return }
            if self.simulationState.isActive || self.simulationState == .updating {
                self.transition(to: .sessionLost)
                self.statusDetail = "Simulation session may no longer be active."
                self.showForceEndControls = true
            }
        }
        simulationService.onPhysicalStageChanged = { [weak self] stage in
            guard let self else { return }
            self.applyPhysicalStage(stage)
        }
        Task {
            await bootstrap()
        }
    }

    /// Called from the app delegate / scene when the user tries to quit.
    func prepareForAppTermination() async -> Bool {
        guard simulationState.isActive || simulationState.isStarting || simulationState == .updating else {
            return true
        }
        showQuitWhileActiveAlert = true
        return await withCheckedContinuation { continuation in
            pendingQuitContinuation = continuation
        }
    }

    func confirmStopAndQuit() {
        showQuitWhileActiveAlert = false
        Task {
            await stopSimulation()
            pendingQuitContinuation?.resume(returning: true)
            pendingQuitContinuation = nil
        }
    }

    func cancelQuit() {
        showQuitWhileActiveAlert = false
        pendingQuitContinuation?.resume(returning: false)
        pendingQuitContinuation = nil
    }

    func quitWithoutStopping() {
        showQuitWhileActiveAlert = false
        pendingQuitContinuation?.resume(returning: true)
        pendingQuitContinuation = nil
    }

    func bootstrap() async {
        toolsStatus = await DeveloperToolsLocator.locate()
        simulationService.updateTools(toolsStatus)
        async let devicesTask: Void = refreshDevices()
        async let locationTask: Void = locateAndSelectCurrentLocation(centerMap: true, recordRecent: false)
        _ = await (devicesTask, locationTask)
    }

    // MARK: - Current location

    func locateAndSelectCurrentLocation(centerMap: Bool, recordRecent: Bool) async {
        isLocating = true
        currentLocationStatusMessage = nil
        defer { isLocating = false }

        currentLocationService.requestAuthorizationIfNeeded()

        do {
            let location = try await currentLocationService.requestCurrentLocation()
            let coordinate = location.coordinate
            guard CoordinateValidation.isValid(coordinate) else {
                currentLocationStatusMessage = "Current location is invalid."
                return
            }

            isResolvingPlace = true
            placeResolutionMessage = "Finding location…"
            let resolved: LocationSearchResult
            do {
                resolved = try await searchService.reverseGeocode(coordinate: coordinate)
            } catch {
                resolved = LocationSearchResult(
                    title: "Current Location",
                    subtitle: String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude),
                    coordinate: coordinate,
                    name: "Current Location",
                    boundingRegion: nil
                )
            }
            isResolvingPlace = false
            placeResolutionMessage = nil

            let mapLocation = MapLocation(
                name: resolved.name.isEmpty ? "Current Location" : resolved.name,
                subtitle: resolved.subtitle.isEmpty ? "Current Location" : resolved.subtitle,
                coordinate: coordinate
            )
            currentLocation = mapLocation
            applySelectedLocation(
                mapLocation,
                region: MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                ),
                centerMap: centerMap,
                recordRecent: recordRecent,
                fromUserEdit: false
            )
            currentLocationStatusMessage = nil
        } catch is CancellationError {
            return
        } catch {
            currentLocationStatusMessage = currentLocationService.authorizationMessage.isEmpty
                ? error.localizedDescription
                : currentLocationService.authorizationMessage
        }
    }

    func recenterOnCurrentLocation() {
        dismissSuggestions(resignFocus: true)
        Task {
            await locateAndSelectCurrentLocation(centerMap: true, recordRecent: false)
        }
    }

    func openLocationSettings() {
        currentLocationService.openLocationSettings()
    }

    // MARK: - Selection

    func applySelectedLocation(
        _ location: MapLocation,
        region: MKCoordinateRegion? = nil,
        centerMap: Bool,
        recordRecent: Bool,
        fromUserEdit: Bool
    ) {
        guard CoordinateValidation.isValid(location.coordinate) else {
            present(error: .invalidCoordinates)
            return
        }

        // Atomic write — name/subtitle/coordinates always come from the same MapLocation.
        selectedLocation = MapLocation(
            id: location.id,
            name: location.name ?? location.displayName,
            subtitle: location.subtitle,
            latitude: location.latitude,
            longitude: location.longitude,
            timestamp: .now
        )
        syncCoordinateFields()

        if centerMap {
            cameraFollowEnabled = true
            let targetRegion = region ?? Self.region(for: selectedLocation)
            cameraPosition = .region(targetRegion)
            visibleMapRegion = targetRegion
            searchService.updateRegionHint(targetRegion)
        }

        if recordRecent {
            store.addRecent(selectedLocation)
            recentLocations = store.loadRecent()
        }

        if fromUserEdit, simulationState.isActive {
            scheduleSimulationUpdate()
        }
    }

    /// Map click / drag: update coordinates immediately, reverse-geocode asynchronously.
    func selectCoordinateFromMap(
        _ coordinate: CLLocationCoordinate2D,
        recordRecentAfterResolve: Bool = true,
        commitToSimulation: Bool = true
    ) {
        dismissSuggestions(resignFocus: true)

        guard CoordinateValidation.isValid(coordinate) else {
            present(error: .invalidCoordinates)
            return
        }

        selectedLocation = MapLocation(
            name: selectedLocation.name ?? "Selected Location",
            subtitle: "Finding location…",
            coordinate: coordinate
        )
        syncCoordinateFields()
        isResolvingPlace = true
        placeResolutionMessage = "Finding location…"

        if commitToSimulation, simulationState.isActive {
            scheduleSimulationUpdate()
        }

        scheduleReverseLookup(for: coordinate, recordRecent: recordRecentAfterResolve)
    }

    /// Marker drag in progress: update UI only — do not send to the device session.
    func previewCoordinateDuringDrag(_ coordinate: CLLocationCoordinate2D) {
        guard CoordinateValidation.isValid(coordinate) else { return }
        selectedLocation = MapLocation(
            name: selectedLocation.name ?? "Selected Location",
            subtitle: selectedLocation.subtitle ?? "Finding location…",
            coordinate: coordinate
        )
        syncCoordinateFields()
    }

    func applyLatitudeLongitudeFields() {
        guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            present(error: .invalidCoordinates)
            syncCoordinateFields()
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CoordinateValidation.isValid(coordinate) else {
            present(error: .invalidCoordinates)
            syncCoordinateFields()
            return
        }

        selectCoordinateFromMap(coordinate, recordRecentAfterResolve: true)
        cameraFollowEnabled = true
        cameraPosition = .region(Self.region(for: coordinate, kind: .street))
    }

    func copyCoordinates() {
        let string = selectedLocation.coordinateString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        statusDetail = "Copied \(string)"
    }

    func userDidPanMap(region: MKCoordinateRegion) {
        cameraFollowEnabled = false
        visibleMapRegion = region
        searchService.updateRegionHint(region)
    }

    func updateVisibleRegion(_ region: MKCoordinateRegion) {
        visibleMapRegion = region
        searchService.updateRegionHint(region)
    }

    private func scheduleReverseLookup(for coordinate: CLLocationCoordinate2D, recordRecent: Bool) {
        reverseLookupTask?.cancel()
        reverseGeneration += 1
        let generation = reverseGeneration

        reverseLookupTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, generation == reverseGeneration else { return }

            do {
                let result = try await searchService.reverseGeocode(coordinate: coordinate)
                guard !Task.isCancelled, generation == reverseGeneration else { return }
                let location = MapLocation(
                    name: result.name,
                    subtitle: result.subtitle.isEmpty ? nil : result.subtitle,
                    coordinate: coordinate
                )
                applySelectedLocation(
                    location,
                    region: nil,
                    centerMap: false,
                    recordRecent: recordRecent,
                    fromUserEdit: true
                )
                isResolvingPlace = false
                placeResolutionMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == reverseGeneration else { return }
                let fallback = MapLocation(
                    name: "Dropped Pin",
                    subtitle: String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude),
                    coordinate: coordinate
                )
                applySelectedLocation(
                    fallback,
                    region: nil,
                    centerMap: false,
                    recordRecent: recordRecent,
                    fromUserEdit: true
                )
                isResolvingPlace = false
                placeResolutionMessage = nil
            }
        }
    }

    private func syncCoordinateFields() {
        latitudeText = String(format: "%.4f", selectedLocation.latitude)
        longitudeText = String(format: "%.4f", selectedLocation.longitude)
    }

    // MARK: - Search

    func searchQueryChanged(_ query: String) {
        // TextField may echo programmatic assignments through its Binding setter.
        // Those must not reopen completions.
        if isProgrammaticSearchQueryUpdate {
            searchQuery = query
            return
        }

        // Genuine user typing — allow completions again.
        suppressSearchCompletions = false
        isResolvingSearch = false
        searchQuery = query
        searchSuggestTask?.cancel()

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchSuggestions = []
            isSearchPanelVisible = false
            highlightedSuggestionIndex = -1
            searchService.updateQueryFragment("")
            return
        }

        searchSuggestTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            guard !self.suppressSearchCompletions, !self.isResolvingSearch else { return }
            searchService.updateRegionHint(visibleMapRegion)
            searchService.updateQueryFragment(query)
        }
    }

    /// Sets the search field text without treating it as user typing.
    private func setSearchQueryProgrammatically(_ value: String) {
        suppressSearchCompletions = true
        searchSuggestTask?.cancel()
        searchService.updateQueryFragment("")
        searchSuggestions = []
        isSearchPanelVisible = false
        highlightedSuggestionIndex = -1
        isProgrammaticSearchQueryUpdate = true
        searchQuery = value
        isProgrammaticSearchQueryUpdate = false
    }

    func clearSearch() {
        suppressSearchCompletions = false
        isResolvingSearch = false
        searchSuggestTask?.cancel()
        searchService.updateQueryFragment("")
        searchQuery = ""
        searchSuggestions = []
        isSearchPanelVisible = false
        highlightedSuggestionIndex = -1
        wantsSearchFocus = true
    }

    func dismissSuggestions(resignFocus: Bool = true) {
        searchSuggestTask?.cancel()
        searchService.updateQueryFragment("")
        searchSuggestions = []
        isSearchPanelVisible = false
        highlightedSuggestionIndex = -1
        if resignFocus {
            wantsSearchFocus = false
            suppressSearchCompletions = true
        }
    }

    func moveSuggestionHighlight(delta: Int) {
        guard shouldShowSearchSuggestions else { return }
        if highlightedSuggestionIndex < 0 {
            highlightedSuggestionIndex = delta > 0 ? 0 : searchSuggestions.count - 1
            return
        }
        let next = highlightedSuggestionIndex + delta
        highlightedSuggestionIndex = max(0, min(searchSuggestions.count - 1, next))
    }

    func confirmHighlightedSuggestionOrSearch() async {
        if shouldShowSearchSuggestions,
           highlightedSuggestionIndex >= 0,
           highlightedSuggestionIndex < searchSuggestions.count {
            await selectSuggestion(searchSuggestions[highlightedSuggestionIndex])
            return
        }
        await performSearch()
    }

    func performSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        beginSearchResolution()
        defer { endSearchResolution() }

        searchTask?.cancel()
        isSearching = true
        defer { isSearching = false }

        do {
            let result = try await searchService.search(query: query, in: visibleMapRegion)
            setSearchQueryProgrammatically(result.title)
            applySearchResult(result)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            present(error: error)
        } catch {
            present(error: .locationSearchFailed(error.localizedDescription))
        }
    }

    func selectSuggestion(_ suggestion: LocationSearchSuggestion) async {
        beginSearchResolution()
        defer { endSearchResolution() }

        isSearching = true
        defer { isSearching = false }

        do {
            let result = try await searchService.resolve(suggestion: suggestion)
            setSearchQueryProgrammatically(result.title)
            applySearchResult(result)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            present(error: error)
        } catch {
            present(error: .locationSearchFailed(error.localizedDescription))
        }
    }

    private func beginSearchResolution() {
        isResolvingSearch = true
        suppressSearchCompletions = true
        searchSuggestTask?.cancel()
        searchService.updateQueryFragment("")
        searchSuggestions = []
        isSearchPanelVisible = false
        highlightedSuggestionIndex = -1
        wantsSearchFocus = false
    }

    private func endSearchResolution() {
        isResolvingSearch = false
        // Keep suppressSearchCompletions true until the user edits the field again.
        suppressSearchCompletions = true
        searchSuggestions = []
        isSearchPanelVisible = false
        wantsSearchFocus = false
    }

    private func applySearchResult(_ result: LocationSearchResult) {
        let location = result.asMapLocation
        let region = result.boundingRegion ?? Self.region(for: location)
        applySelectedLocation(
            location,
            region: region,
            centerMap: true,
            recordRecent: true,
            fromUserEdit: true
        )
        searchSuggestions = []
        isSearchPanelVisible = false
        wantsSearchFocus = false
        if simulationState.isActive {
            statusDetail = "Simulating at \(result.title)"
        } else {
            statusDetail = "Selected: \(result.title)"
        }
    }

    // MARK: - Devices

    func refreshDevices() async {
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }

        do {
            let found = try await deviceService.discoverDevices(tools: toolsStatus)
            devices = found
            if let selectedDeviceID,
               found.contains(where: { $0.id == selectedDeviceID }) {
                // keep
            } else {
                if simulationState.isActive || simulationState == .updating {
                    transition(to: .deviceDisconnected)
                    statusDetail = "iPhone disconnected. Simulation session may no longer be active."
                    showForceEndControls = true
                }
                self.selectedDeviceID = found.first(where: \.isAvailable)?.id ?? found.first?.id
            }
            if found.isEmpty {
                statusDetail = statusDetail ?? "Connect an iPhone by USB to start a physical developer location session."
            } else if simulationState == .deviceDisconnected,
                      let selected = selectedDevice,
                      found.contains(where: { $0.id == selected.id }) {
                statusDetail = "iPhone Reconnected"
            }
        } catch let error as AppError {
            devices = []
            selectedDeviceID = nil
            lastError = error
            statusDetail = error.localizedDescription
        } catch {
            devices = []
            selectedDeviceID = nil
            statusDetail = error.localizedDescription
        }
    }

    // MARK: - Simulation

    func startSimulation() async {
        guard let device = selectedDevice else {
            present(error: .noDeviceSelected)
            return
        }
        if isDeveloperModeDisabled {
            present(error: .developerModeUnavailable)
            return
        }
        guard CoordinateValidation.isValid(selectedCoordinate) else {
            present(error: .invalidCoordinates)
            return
        }
        switch simulationState {
        case .idle, .failed, .sessionLost, .deviceDisconnected:
            break
        default:
            return
        }
        if simulationState != .idle {
            transition(to: .idle)
        }

        if let issue = physicalSetupIssue {
            present(error: .simulationStartFailed(deviceName: device.name, details: issue))
            return
        }

        updateDebounceTask?.cancel()
        pendingUpdateCoordinate = nil
        showForceEndControls = false
        transition(to: .preparing)
        statusDetail = SimulationState.preparing.stageDescription
        lastError = nil

        do {
            let outcome = try await simulationService.startSimulation(
                device: device,
                coordinate: selectedCoordinate
            )
            switch outcome {
            case .started:
                transition(to: .active)
                statusDetail = activeStatusDetail()
                store.addRecent(selectedLocation)
                recentLocations = store.loadRecent()
            case .preparedManualXcodeSession(let session):
                transition(to: .idle)
                preparedManualSession = session
                showManualXcodeSheet = true
                statusDetail = "Prepared Xcode session for \(session.coordinateSummary)"
            }
        } catch let error as AppError {
            transition(to: .failed(error.localizedDescription))
            present(error: error)
        } catch {
            let message = error.localizedDescription
            transition(to: .failed(message))
            present(error: .commandExecutionFailed(message))
        }
    }

    func openPreparedXcodeProject() {
        simulationService.openProjectInXcode()
    }

    func revealPreparedGPX() {
        simulationService.revealGeneratedGPX()
    }

    var canStopSimulation: Bool {
        simulationState.isActive
            || simulationState == .sessionLost
            || simulationState == .deviceDisconnected
    }

    func clearLocationAfterSessionLoss() async {
        guard let device = selectedDevice else {
            present(error: .noDeviceSelected)
            return
        }
        transition(to: .stopping)
        statusDetail = SimulationState.stopping.stageDescription
        do {
            try await simulationService.emergencyClearLocation(device: device)
            transition(to: .idle)
            showForceEndControls = false
            statusDetail = "Location cleared"
        } catch let error as AppError {
            transition(to: .failed(error.localizedDescription))
            present(error: error)
        } catch {
            transition(to: .failed(error.localizedDescription))
            present(error: .simulationStopFailed(error.localizedDescription))
        }
    }

    func forceEndSession() async {
        transition(to: .stopping)
        statusDetail = "Ending session…"
        await simulationService.forceEndPhysicalSession()
        transition(to: .sessionLost)
        showForceEndControls = true
        statusDetail = "The developer session could not confirm that the simulated location was cleared."
    }

    func stopSimulation() async {
        guard canStopSimulation || simulationState.isActive else { return }
        if simulationState.isBusy && !simulationState.isActive && simulationState != .updating {
            return
        }
        updateDebounceTask?.cancel()
        pendingUpdateCoordinate = nil
        transition(to: .stopping)
        statusDetail = SimulationState.stopping.stageDescription
        do {
            try await simulationService.stopSimulation()
            if simulationService.lastPhysicalStopResult == .forceEndedWithoutClearConfirmation {
                transition(to: .sessionLost)
                showForceEndControls = true
                statusDetail = "The developer session could not confirm that the simulated location was cleared."
            } else {
                transition(to: .idle)
                showForceEndControls = false
                statusDetail = "Simulation stopped"
            }
        } catch let error as AppError {
            transition(to: .failed(error.localizedDescription))
            showForceEndControls = true
            present(error: error)
        } catch {
            let message = error.localizedDescription
            transition(to: .failed(message))
            showForceEndControls = true
            present(error: .simulationStopFailed(message))
        }
    }

    private func scheduleSimulationUpdate() {
        pendingUpdateCoordinate = selectedCoordinate
        updateDebounceTask?.cancel()
        updateDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, simulationState.isActive || simulationState == .updating else { return }
            await processPendingSimulationUpdates()
        }
    }

    func scheduleRetryUpdate() {
        scheduleSimulationUpdate()
    }

    /// Debug harness only: same-session update used by `--debug-gui-button-start-cn`.
    func debugUpdateSimulation(coordinate: CLLocationCoordinate2D) async throws {
        applySelectedLocation(
            MapLocation(name: "Times Square", subtitle: "New York, NY", coordinate: coordinate),
            centerMap: true,
            recordRecent: false,
            fromUserEdit: false
        )
        try await simulationService.updateSimulation(coordinate: coordinate)
    }

    var debugOwnedProcessRunning: Bool {
        simulationService.ownedPhysicalProcessRunning
    }

    private func processPendingSimulationUpdates() async {
        if let existing = updateSerialTask {
            await existing.value
        }

        updateSerialTask = Task {
            while simulationState.isActive || simulationState == .updating {
                guard let coordinate = pendingUpdateCoordinate else { break }
                pendingUpdateCoordinate = nil
                transition(to: .updating)
                statusDetail = "Updating…"
                do {
                    try await simulationService.updateSimulation(coordinate: coordinate)
                    if !Task.isCancelled {
                        // Latest-wins: if a newer coordinate arrived during the update, loop again.
                        if pendingUpdateCoordinate == nil {
                            transition(to: .active)
                            statusDetail = activeStatusDetail()
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        if simulationService.ownedPhysicalProcessRunning == false {
                            transition(to: .sessionLost)
                            showForceEndControls = true
                            statusDetail = "Simulation session may no longer be active."
                        } else {
                            transition(to: .active)
                            statusDetail = activeStatusDetail()
                            if let appError = error as? AppError {
                                present(error: .locationUpdateFailed(appError.technicalDetails ?? appError.localizedDescription))
                            } else {
                                present(error: .locationUpdateFailed(error.localizedDescription))
                            }
                        }
                    }
                    break
                }
            }
        }
        await updateSerialTask?.value
        updateSerialTask = nil
    }

    private func applyPhysicalStage(_ stage: PhysicalSessionStage) {
        let mapped: SimulationState
        switch stage {
        case .idle:
            return
        case .preparing:
            mapped = .preparing
        case .launchingTestRunner:
            mapped = .launchingTestRunner
        case .waitingForConnection:
            mapped = .waitingForConnection
        case .applyingInitialLocation:
            mapped = .applyingInitialLocation
        case .active:
            mapped = .active
        case .updating:
            mapped = .updating
        case .stopping:
            mapped = .stopping
        }
        if simulationState.canTransition(to: mapped) || simulationState.isStarting {
            simulationState = mapped
            if let stageDescription = mapped.stageDescription {
                statusDetail = stageDescription
            }
        }
    }

    private func transition(to next: SimulationState) {
        guard simulationState.canTransition(to: next) || next == .idle || next == .failed(next.failureMessage ?? "") else {
            // Allow recovery transitions into failed/idle more permissively.
            if case .failed = next {
                simulationState = next
                return
            }
            if next == .idle {
                simulationState = .idle
                return
            }
            return
        }
        simulationState = next
    }

    private func activeStatusDetail() -> String {
        var lines = [selectedLocation.displayName]
        if let subtitle = selectedLocation.subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        lines.append(selectedLocation.coordinateString)
        return lines.joined(separator: "\n")
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Favorites / Recents

    func saveFavorite() {
        store.addFavorite(selectedLocation)
        favoriteLocations = store.loadFavorites()
        statusDetail = "Saved favorite"
    }

    func selectStoredLocation(_ location: MapLocation) {
        dismissSuggestions(resignFocus: true)
        applySelectedLocation(
            location,
            region: Self.region(for: location),
            centerMap: true,
            recordRecent: true,
            fromUserEdit: true
        )
        setSearchQueryProgrammatically(location.displayName)
        if simulationState.isActive {
            statusDetail = activeStatusDetail()
        } else {
            statusDetail = "Selected: \(location.displayName)"
        }
    }

    func zoomIn() {
        adjustZoom(factor: 0.5)
    }

    func zoomOut() {
        adjustZoom(factor: 2.0)
    }

    private func adjustZoom(factor: Double) {
        let base = visibleMapRegion
            ?? cameraPosition.region
            ?? MKCoordinateRegion(
                center: selectedCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        var span = base.span
        span.latitudeDelta = min(max(span.latitudeDelta * factor, 0.0008), 80)
        span.longitudeDelta = min(max(span.longitudeDelta * factor, 0.0008), 80)
        let region = MKCoordinateRegion(center: base.center, span: span)
        cameraFollowEnabled = true
        cameraPosition = .region(region)
        visibleMapRegion = region
    }

    func removeFavorite(_ location: MapLocation) {
        store.removeFavorite(location)
        favoriteLocations = store.loadFavorites()
    }

    func clearRecentLocations() {
        store.clearRecent()
        recentLocations = []
    }

    // MARK: - Camera helpers

    enum RegionKind {
        case street
        case poi
        case city
        case country
        case world
    }

    static func region(for location: MapLocation) -> MKCoordinateRegion {
        region(for: location.coordinate, kind: inferKind(for: location))
    }

    static func region(for coordinate: CLLocationCoordinate2D, kind: RegionKind) -> MKCoordinateRegion {
        let span: MKCoordinateSpan
        switch kind {
        case .street:
            span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        case .poi:
            span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        case .city:
            span = MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        case .country:
            span = MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12)
        case .world:
            span = MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 80)
        }
        return MKCoordinateRegion(center: coordinate, span: span)
    }

    private static func inferKind(for location: MapLocation) -> RegionKind {
        let text = ((location.name ?? "") + " " + (location.subtitle ?? "")).lowercased()
        if text.contains("airport") || text.contains("station") || text.contains("university") {
            return .poi
        }
        if location.subtitle == nil || location.subtitle?.isEmpty == true {
            return .city
        }
        if text.contains(",") && (text.contains("st") || text.contains("ave") || text.contains("rd") || text.contains("blvd")) {
            return .street
        }
        if location.name?.split(separator: " ").count == 1 && (location.subtitle?.isEmpty ?? true) {
            return .city
        }
        return .poi
    }

    // MARK: - Errors

    private func present(error: AppError) {
        lastError = error
        errorAlertTitle = error.alertTitle
        errorAlertMessage = error.localizedDescription
        errorTechnicalDetails = error.technicalDetails
        showErrorAlert = true
    }
}

//
//  MapView.swift
//  ChangeMe
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI

struct InteractiveMapView: NSViewRepresentable {
    @Binding var selectedCoordinate: CLLocationCoordinate2D
    var currentCoordinate: CLLocationCoordinate2D?
    var showCurrentMarker: Bool
    var mapRegion: MKCoordinateRegion
    var followCamera: Bool
    var onSelectCoordinate: (CLLocationCoordinate2D) -> Void
    var onDragEnded: (CLLocationCoordinate2D) -> Void
    var onUserPan: (MKCoordinateRegion) -> Void
    var onRegionChange: (MKCoordinateRegion) -> Void
    /// Fired after a programmatic camera apply settles — used to stop one-shot follow.
    var onProgrammaticCameraApplied: () -> Void
    var onContextCopy: (CLLocationCoordinate2D) -> Void
    var onContextCenter: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsZoomControls = false
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false
        mapView.showsBuildings = true

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.numberOfClicksRequired = 1
        click.delegate = context.coordinator
        mapView.addGestureRecognizer(click)

        let rightClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClick.buttonMask = 0x2
        mapView.addGestureRecognizer(rightClick)

        context.coordinator.mapView = mapView
        context.coordinator.syncAnnotations(on: mapView)
        context.coordinator.applyRegion(mapRegion, to: mapView, animated: false)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncAnnotations(on: mapView)

        if followCamera, context.coordinator.shouldApplyRegion(mapRegion) {
            context.coordinator.applyRegion(mapRegion, to: mapView, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: InteractiveMapView
        weak var mapView: MKMapView?
        let selectedAnnotation = SelectedLocationAnnotation()
        let currentAnnotation = CurrentLocationAnnotation()
        var isDragging = false
        /// True while MKMapView is applying a model-driven setRegion (not a user gesture).
        private var isApplyingProgrammaticRegion = false
        private var programmaticRegionGeneration = 0

        init(parent: InteractiveMapView) {
            self.parent = parent
            super.init()
            selectedAnnotation.title = "Selected Location"
            selectedAnnotation.coordinate = parent.selectedCoordinate
        }

        func syncAnnotations(on mapView: MKMapView) {
            if !isDragging {
                selectedAnnotation.coordinate = parent.selectedCoordinate
            }
            if !mapView.annotations.contains(where: { $0 === selectedAnnotation }) {
                mapView.addAnnotation(selectedAnnotation)
            }

            if parent.showCurrentMarker, let current = parent.currentCoordinate {
                currentAnnotation.coordinate = current
                if !mapView.annotations.contains(where: { $0 === currentAnnotation }) {
                    mapView.addAnnotation(currentAnnotation)
                }
            } else if mapView.annotations.contains(where: { $0 === currentAnnotation }) {
                mapView.removeAnnotation(currentAnnotation)
            }
        }

        func shouldApplyRegion(_ region: MKCoordinateRegion) -> Bool {
            guard let mapView else { return true }
            if isApplyingProgrammaticRegion { return false }
            let current = mapView.region
            let centerClose = coordinatesApproximatelyEqual(current.center, region.center)
            let spanClose =
                abs(current.span.latitudeDelta - region.span.latitudeDelta) < 0.001
                && abs(current.span.longitudeDelta - region.span.longitudeDelta) < 0.001
            return !(centerClose && spanClose)
        }

        func applyRegion(_ region: MKCoordinateRegion, to mapView: MKMapView, animated: Bool) {
            programmaticRegionGeneration += 1
            let generation = programmaticRegionGeneration
            isApplyingProgrammaticRegion = true
            mapView.setRegion(region, animated: animated)
            // Animated setRegion may deliver regionDidChange after this returns;
            // clear the flag on the next main turn if the delegate did not.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.programmaticRegionGeneration == generation else { return }
                if self.isApplyingProgrammaticRegion {
                    self.isApplyingProgrammaticRegion = false
                    self.parent.onProgrammaticCameraApplied()
                }
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            if let hit = mapView.hitTest(point), hit is MKAnnotationView {
                return
            }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onSelectCoordinate(coordinate)
        }

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)

            let menu = NSMenu()
            menu.addItem(withTitle: "Set Location Here", action: #selector(setLocationHere(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Coordinates", action: #selector(copyCoordinates(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Center Map Here", action: #selector(centerHere(_:)), keyEquivalent: "")
            for item in menu.items {
                item.target = self
                item.representedObject = CoordinateBox(coordinate)
            }
            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: mapView)
        }

        @objc private func setLocationHere(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? CoordinateBox else { return }
            parent.onSelectCoordinate(box.coordinate)
        }

        @objc private func copyCoordinates(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? CoordinateBox else { return }
            parent.onContextCopy(box.coordinate)
        }

        @objc private func centerHere(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? CoordinateBox else { return }
            parent.onContextCenter(box.coordinate)
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard let mapView else { return true }
            let point = gestureRecognizer.location(in: mapView)
            if let hit = mapView.hitTest(point), hit is MKAnnotationView {
                return false
            }
            return true
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Detected via regionDidChange.
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region

            // Programmatic model → map: never feed region back into SwiftUI during
            // updateNSView / setRegion (that caused AttributeGraph / reentrant layout).
            if isApplyingProgrammaticRegion {
                isApplyingProgrammaticRegion = false
                let applied = parent.onProgrammaticCameraApplied
                DispatchQueue.main.async {
                    applied()
                }
                return
            }

            // User map → model: defer off the current layout / render pass.
            let onRegionChange = parent.onRegionChange
            let onUserPan = parent.onUserPan
            DispatchQueue.main.async {
                onRegionChange(region)
                onUserPan(region)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is SelectedLocationAnnotation {
                let reuseID = "changeme.selected.location"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
                view.annotation = annotation
                view.canShowCallout = true
                view.isDraggable = true
                view.displayPriority = .required
                view.collisionMode = .none
                view.image = selectedMarkerImage()
                view.centerOffset = CGPoint(x: 0, y: -22)
                return view
            }

            if annotation is CurrentLocationAnnotation {
                let reuseID = "changeme.current.location"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
                view.annotation = annotation
                view.canShowCallout = false
                view.isDraggable = false
                view.displayPriority = .defaultHigh
                view.image = currentMarkerImage()
                view.centerOffset = .zero
                return view
            }

            return nil
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            guard view.annotation is SelectedLocationAnnotation else { return }
            switch newState {
            case .starting:
                isDragging = true
            case .ending, .canceling:
                isDragging = false
                view.dragState = .none
                if let coordinate = view.annotation?.coordinate {
                    parent.onDragEnded(coordinate)
                }
            default:
                break
            }
        }

        private func selectedMarkerImage() -> NSImage {
            let size = NSSize(width: 36, height: 48)
            return NSImage(size: size, flipped: false) { rect in
                // Pointer / stem tip at the exact coordinate (bottom center).
                let tip = NSPoint(x: rect.midX, y: 1)
                let pointer = NSBezierPath()
                pointer.move(to: tip)
                pointer.line(to: NSPoint(x: rect.midX - 7, y: 14))
                pointer.line(to: NSPoint(x: rect.midX + 7, y: 14))
                pointer.close()
                NSColor.systemBlue.setFill()
                pointer.fill()

                let circleRect = NSRect(x: 6, y: 12, width: 24, height: 24)
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: circleRect.insetBy(dx: 5, dy: 5)).fill()

                if let symbol = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "Selected location") {
                    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                    let configured = symbol.withSymbolConfiguration(config) ?? symbol
                    configured.draw(
                        in: NSRect(x: 11, y: 17, width: 14, height: 14),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0
                    )
                }
                return true
            }
        }

        private func currentMarkerImage() -> NSImage {
            let size = NSSize(width: 22, height: 22)
            return NSImage(size: size, flipped: false) { rect in
                NSColor.systemBlue.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6)).fill()
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
                ring.lineWidth = 2
                ring.stroke()
                return true
            }
        }
    }
}

final class SelectedLocationAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D = .init()
    var title: String?
    var subtitle: String?
}

final class CurrentLocationAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D = .init()
    var title: String? = "Current Location"
}

private final class CoordinateBox: NSObject {
    let coordinate: CLLocationCoordinate2D
    init(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

private func coordinatesApproximatelyEqual(
    _ a: CLLocationCoordinate2D,
    _ b: CLLocationCoordinate2D
) -> Bool {
    abs(a.latitude - b.latitude) < 0.00001 && abs(a.longitude - b.longitude) < 0.00001
}

struct MapView: View {
    @Bindable var viewModel: LocationViewModel

    private var resolvedMapRegion: MKCoordinateRegion {
        if let region = viewModel.cameraPosition.region {
            return region
        }
        return MKCoordinateRegion(
            center: viewModel.selectedCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            InteractiveMapView(
                selectedCoordinate: Binding(
                    get: { viewModel.selectedCoordinate },
                    set: { viewModel.previewCoordinateDuringDrag($0) }
                ),
                currentCoordinate: viewModel.currentLocation?.coordinate,
                showCurrentMarker: viewModel.showsCurrentLocationMarker,
                mapRegion: resolvedMapRegion,
                followCamera: viewModel.cameraFollowEnabled,
                onSelectCoordinate: { coordinate in
                    viewModel.selectCoordinateFromMap(coordinate)
                },
                onDragEnded: { coordinate in
                    viewModel.selectCoordinateFromMap(coordinate, recordRecentAfterResolve: true, commitToSimulation: true)
                },
                onUserPan: { region in
                    viewModel.userDidPanMap(region: region)
                },
                onRegionChange: { region in
                    viewModel.updateVisibleRegion(region)
                },
                onProgrammaticCameraApplied: {
                    // One-shot follow: after model-driven setRegion settles, stop forcing
                    // the camera so search/pan/selection are not overridden.
                    viewModel.cameraFollowEnabled = false
                },
                onContextCopy: { coordinate in
                    viewModel.selectCoordinateFromMap(coordinate, recordRecentAfterResolve: false)
                    viewModel.copyCoordinates()
                },
                onContextCenter: { coordinate in
                    viewModel.cameraFollowEnabled = true
                    viewModel.cameraPosition = .region(
                        MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        )
                    )
                }
            )

            // Floating search — sized to its content so map clicks outside still work.
            SearchBarView(viewModel: viewModel)
                .padding(16)
                .frame(maxWidth: 520, alignment: .leading)
                .allowsHitTesting(true)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    mapControlCluster
                        .padding(.trailing, 16)
                        .padding(.bottom, 28) // keep clear of MapKit legal attribution
                }
            }
        }
    }

    private var mapControlCluster: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                Button {
                    viewModel.zoomIn()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .help("Zoom In")
                .accessibilityLabel("Zoom In")

                Divider().frame(width: 28)

                Button {
                    viewModel.zoomOut()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 20)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .help("Zoom Out")
                .accessibilityLabel("Zoom Out")
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

            Button {
                viewModel.recenterOnCurrentLocation()
            } label: {
                Group {
                    if viewModel.isLocating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "location.fill")
                    }
                }
                .frame(width: 20, height: 20)
                .padding(10)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .help("Current Location")
            .accessibilityLabel("Current Location")
        }
    }
}

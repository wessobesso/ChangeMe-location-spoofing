//
//  LocationSearchService.swift
//  ChangeMe
//

import CoreLocation
import Foundation
import MapKit

struct LocationSearchResult: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let name: String
    let boundingRegion: MKCoordinateRegion?

    var asMapLocation: MapLocation {
        MapLocation(
            name: name,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            coordinate: coordinate
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocationSearchResult, rhs: LocationSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

struct LocationSearchSuggestion: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion

    var symbolName: String {
        Self.symbol(for: title, subtitle: subtitle)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocationSearchSuggestion, rhs: LocationSearchSuggestion) -> Bool {
        lhs.id == rhs.id
    }

    static func symbol(for title: String, subtitle: String) -> String {
        // Conservative heuristics for unresolved autocomplete rows.
        let text = (title + " " + subtitle).lowercased()
        if text.contains("airport") || text.contains("aeroport") {
            return "airplane"
        }
        if text.contains("university") || text.contains("college") || text.contains("school") {
            return "graduationcap.fill"
        }
        if text.contains("hospital") || text.contains("clinic") || text.contains("medical") {
            return "cross.case.fill"
        }
        if text.contains("starbucks") || text.contains("coffee") || text.contains("café") || text.contains("cafe") {
            return "cup.and.saucer.fill"
        }
        if text.contains("restaurant") || text.contains("mcdonald") || text.contains("pizza") || text.contains("burger") {
            return "fork.knife"
        }
        if text.contains("store") || text.contains("mall") || text.contains("walmart") || text.contains("market") {
            return "storefront.fill"
        }
        // Prefer house for address-looking completions; generic pin otherwise.
        if subtitle.lowercased().contains("st")
            || subtitle.lowercased().contains("ave")
            || subtitle.lowercased().contains("rd")
            || subtitle.lowercased().contains("blvd")
            || subtitle.lowercased().contains("dr") {
            return "house.fill"
        }
        return "mappin.circle.fill"
    }
}

@MainActor
final class LocationSearchService: NSObject {
    private let completer = MKLocalSearchCompleter()
    private var suggestionHandler: (([LocationSearchSuggestion]) -> Void)?
    private var suggestionGeneration = 0
    private var searchGeneration = 0

    private(set) var regionHint: MKCoordinateRegion?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = MKLocalSearchCompleter.ResultType.address
            .union(.pointOfInterest)
            .union(.query)
    }

    func updateRegionHint(_ region: MKCoordinateRegion?) {
        regionHint = region
        if let region {
            completer.region = region
        }
    }

    func updateQueryFragment(_ fragment: String) {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionGeneration += 1
        if trimmed.isEmpty {
            suggestionHandler?([])
            completer.queryFragment = ""
            return
        }
        if let regionHint {
            completer.region = regionHint
        }
        completer.queryFragment = trimmed
    }

    func onSuggestions(_ handler: @escaping ([LocationSearchSuggestion]) -> Void) {
        suggestionHandler = handler
    }

    func search(query: String, in region: MKCoordinateRegion? = nil) async throws -> LocationSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.locationSearchFailed("Enter a place or address to search.")
        }

        searchGeneration += 1
        let generation = searchGeneration

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = MKLocalSearch.ResultType.address.union(.pointOfInterest)
        if let region = region ?? regionHint {
            request.region = region
        }

        let search = MKLocalSearch(request: request)
        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch {
            throw AppError.locationSearchFailed(error.localizedDescription)
        }

        guard generation == searchGeneration else {
            throw CancellationError()
        }

        guard let item = response.mapItems.first else {
            throw AppError.locationSearchFailed("No results found for “\(trimmed)”.")
        }

        return try makeResult(from: item, fallbackTitle: trimmed, boundingRegion: response.boundingRegion)
    }

    func resolve(suggestion: LocationSearchSuggestion) async throws -> LocationSearchResult {
        searchGeneration += 1
        let generation = searchGeneration

        let request = MKLocalSearch.Request(completion: suggestion.completion)
        let search = MKLocalSearch(request: request)
        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch {
            throw AppError.locationSearchFailed(error.localizedDescription)
        }

        guard generation == searchGeneration else {
            throw CancellationError()
        }

        guard let item = response.mapItems.first else {
            throw AppError.locationSearchFailed("Could not resolve “\(suggestion.title)”.")
        }

        return try makeResult(
            from: item,
            fallbackTitle: suggestion.title,
            boundingRegion: response.boundingRegion
        )
    }

    /// Reverse-resolve a coordinate into a place/address.
    func reverseGeocode(coordinate: CLLocationCoordinate2D) async throws -> LocationSearchResult {
        guard CoordinateValidation.isValid(coordinate) else {
            throw AppError.invalidCoordinates
        }

        searchGeneration += 1
        let generation = searchGeneration

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        if let request = MKReverseGeocodingRequest(location: location) {
            do {
                let items = try await request.mapItems
                guard generation == searchGeneration else { throw CancellationError() }
                if let item = items.first {
                    return try makeResult(from: item, fallbackTitle: nil, boundingRegion: nil)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to local search fallback.
            }
        }

        // Fallback: natural-language coordinate search.
        let query = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = MKLocalSearch.ResultType.address.union(.pointOfInterest)
        request.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )

        let response = try await MKLocalSearch(request: request).start()
        guard generation == searchGeneration else { throw CancellationError() }

        if let item = response.mapItems.first,
           let result = try? makeResult(from: item, fallbackTitle: nil, boundingRegion: nil),
           CoordinateValidation.approximatelyEqual(result.coordinate, coordinate, tolerance: 0.05) {
            return LocationSearchResult(
                title: result.title,
                subtitle: result.subtitle,
                coordinate: coordinate,
                name: result.name,
                boundingRegion: nil
            )
        }

        let coordTitle = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        return LocationSearchResult(
            title: "Dropped Pin",
            subtitle: coordTitle,
            coordinate: coordinate,
            name: "Dropped Pin",
            boundingRegion: nil
        )
    }

    private func makeResult(
        from item: MKMapItem,
        fallbackTitle: String?,
        boundingRegion: MKCoordinateRegion?
    ) throws -> LocationSearchResult {
        guard let coordinate = mapItemCoordinate(item) else {
            throw AppError.locationSearchFailed("The search result had invalid coordinates.")
        }

        let name = item.name
            ?? mapItemTitle(item)
            ?? fallbackTitle
            ?? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)

        let subtitle = mapItemSubtitle(item)

        return LocationSearchResult(
            title: name,
            subtitle: subtitle,
            coordinate: coordinate,
            name: name,
            boundingRegion: boundingRegion
        )
    }

    private func mapItemCoordinate(_ item: MKMapItem) -> CLLocationCoordinate2D? {
        let coordinate = item.location.coordinate
        guard CoordinateValidation.isValid(coordinate) else { return nil }
        return coordinate
    }

    private func mapItemTitle(_ item: MKMapItem) -> String? {
        if let shortAddress = item.address?.shortAddress, !shortAddress.isEmpty {
            return shortAddress
        }
        if let fullAddress = item.address?.fullAddress, !fullAddress.isEmpty {
            return fullAddress
        }
        if let full = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true),
           !full.isEmpty {
            return full
        }
        return nil
    }

    private func mapItemSubtitle(_ item: MKMapItem) -> String {
        if let full = item.address?.fullAddress, !full.isEmpty, full != item.name {
            return full
        }
        if let context = item.addressRepresentations?.cityWithContext(.full), !context.isEmpty {
            return context
        }
        if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty {
            return city
        }
        if let shortAddress = item.address?.shortAddress, !shortAddress.isEmpty, shortAddress != item.name {
            return shortAddress
        }
        if let multi = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: false),
           !multi.isEmpty {
            return multi.replacingOccurrences(of: "\n", with: ", ")
        }
        return ""
    }
}

extension LocationSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results.prefix(6).map {
            LocationSearchSuggestion(
                title: $0.title,
                subtitle: $0.subtitle,
                completion: $0
            )
        }
        Task { @MainActor in
            self.suggestionHandler?(Array(mapped))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestionHandler?([])
        }
    }
}

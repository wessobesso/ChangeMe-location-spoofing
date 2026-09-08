//
//  SearchBarView.swift
//  ChangeMe
//

import SwiftUI

struct SearchBarView: View {
    @Bindable var viewModel: LocationViewModel
    @FocusState private var isSearchFocused: Bool

    private var shouldShowSuggestions: Bool {
        viewModel.shouldShowSearchSuggestions
    }

    var body: some View {
        // Two distinct vertical regions — never one shared clipped card.
        VStack(alignment: .leading, spacing: 8) {
            searchFieldCard

            if shouldShowSuggestions {
                suggestionsCard
            }
        }
        .frame(minWidth: 320, idealWidth: 440, maxWidth: 480, alignment: .leading)
        .onKeyPress(.upArrow) {
            viewModel.moveSuggestionHighlight(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSuggestionHighlight(delta: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.dismissSuggestions(resignFocus: true)
            isSearchFocused = false
            return .handled
        }
        .onChange(of: viewModel.wantsSearchFocus) { _, wants in
            isSearchFocused = wants
        }
        .onChange(of: isSearchFocused) { _, focused in
            viewModel.wantsSearchFocus = focused
        }
    }

    private var searchFieldCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search for a place or address…", text: Binding(
                get: { viewModel.searchQuery },
                set: { viewModel.searchQueryChanged($0) }
            ))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .onSubmit {
                Task {
                    await viewModel.confirmHighlightedSuggestionOrSearch()
                    isSearchFocused = false
                }
            }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.clearSearch()
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var suggestionsCard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.searchSuggestions.prefix(6).enumerated()), id: \.element.id) { index, suggestion in
                    suggestionRow(index: index, suggestion: suggestion)

                    if index < min(5, viewModel.searchSuggestions.count - 1) {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func suggestionRow(index: Int, suggestion: LocationSearchSuggestion) -> some View {
        let isHighlighted = index == viewModel.highlightedSuggestionIndex

        return Button {
            Task {
                await viewModel.selectSuggestion(suggestion)
                isSearchFocused = false
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: suggestion.symbolName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                viewModel.highlightedSuggestionIndex = index
            }
        }
    }
}

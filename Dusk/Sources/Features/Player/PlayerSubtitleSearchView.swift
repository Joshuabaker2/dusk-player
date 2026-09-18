#if !os(tvOS)
import SwiftUI

/// Everything the search screen needs, resolved once by the player so both
/// subtitle surfaces (the standalone picker sheet and the playback-settings
/// sheet) open the same search with the same follow-up behavior.
struct PlayerSubtitleSearchConfiguration {
    let plexService: PlexService
    let ratingKey: String
    let language: String
    /// Subtitle streams already on the item, so the search can tell which one
    /// the server just added.
    let knownSubtitleStreamIDs: Set<Int>
    let onDownloaded: (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void
}

/// In-player subtitle search, reached from "Find More…" in the subtitle picker.
///
/// The server does the matching (by title, season/episode and file hash) and
/// the downloading; this lists what it found — file name, provider and download
/// count — and applies the chosen result to the running session.
struct PlayerSubtitleSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerSubtitleSearchViewModel
    @State private var directionalFocus: String?

    /// Called once the downloaded subtitle is on the item and ready to select.
    let onDownloaded: (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void

    init(
        plexService: PlexService,
        ratingKey: String,
        language: String,
        knownSubtitleStreamIDs: Set<Int>,
        onDownloaded: @escaping (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void
    ) {
        _viewModel = State(
            initialValue: PlayerSubtitleSearchViewModel(
                plexService: plexService,
                ratingKey: ratingKey,
                language: language,
                knownSubtitleStreamIDs: knownSubtitleStreamIDs
            )
        )
        self.onDownloaded = onDownloaded
    }

    init(
        configuration: PlayerSubtitleSearchConfiguration,
        onDownloaded: @escaping (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void
    ) {
        self.init(
            plexService: configuration.plexService,
            ratingKey: configuration.ratingKey,
            language: configuration.language,
            knownSubtitleStreamIDs: configuration.knownSubtitleStreamIDs,
            onDownloaded: onDownloaded
        )
    }

    var body: some View {
        @Bindable var searchViewModel = viewModel

        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(viewModel.results.map(\.key), columnCount: 1)],
            defaultFocus: viewModel.results.first?.key,
            isEnabled: supportsDirectionalSelection,
            onActivate: activateDirectionalFocus,
            onBack: {
                dismiss()
                return true
            }
        ) {
            List {
                Section {
                    Picker("Language", selection: $searchViewModel.language) {
                        ForEach(CommonLanguage.allCases) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .foregroundStyle(Color.duskTextPrimary)
                    .listRowBackground(Color.duskSurface)
                }

                Section {
                    resultsContent
                } footer: {
                    if !viewModel.results.isEmpty {
                        Text("Subtitles are downloaded to your Plex server, so they're available on every device.")
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
            }
            .duskScrollContentBackgroundHidden()
            .background(Color.duskBackground)
        }
        .duskNavigationTitle("Find Subtitles")
        .duskNavigationBarTitleDisplayModeInline()
        .task { await viewModel.load() }
        .alert(
            "Couldn't Add Subtitle",
            isPresented: Binding(
                get: { viewModel.actionErrorMessage != nil },
                set: { if !$0 { viewModel.clearActionError() } }
            ),
            presenting: viewModel.actionErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { viewModel.clearActionError() }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isLoading, viewModel.results.isEmpty {
            FeatureLoadingView()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } else if let errorMessage = viewModel.errorMessage, viewModel.results.isEmpty {
            FeatureErrorView(message: errorMessage) {
                Task { await viewModel.load() }
            }
            .listRowBackground(Color.clear)
        } else if viewModel.results.isEmpty {
            FeatureEmptyStateView(
                systemImage: "captions.bubble",
                title: "No Subtitles Found",
                // Subtitle search runs entirely on the server, so an empty list
                // usually means the provider isn't set up there rather than
                // that nothing exists.
                message: "Try another language, or check that subtitle search is enabled on your Plex server."
            )
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        } else {
            ForEach(viewModel.results) { result in
                resultRow(result)
            }
        }
    }

    private func resultRow(_ result: PlexSubtitleSearchResult) -> some View {
        Button {
            download(result)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.displayTitle)
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let detail = detailLine(for: result) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    if !badges(for: result).isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges(for: result), id: \.self) { badge in
                                badgeLabel(badge)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                if viewModel.downloadingKey == result.key {
                    ProgressView()
                        .tint(Color.duskAccent)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.downloadingKey != nil)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            supportsDirectionalSelection && directionalFocus == result.key,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id(result.key)
        .listRowBackground(Color.duskSurface)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.duskTextPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.duskSurface.opacity(0.86), in: Capsule())
            .overlay {
                Capsule().stroke(Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
            }
    }

    /// Provider, popularity and format — the same signals the Plex app shows,
    /// and what tells one release-matched file from another.
    private func detailLine(for result: PlexSubtitleSearchResult) -> String? {
        var parts: [String] = []

        if let provider = result.providerTitle?.nilIfEmpty {
            parts.append(provider)
        }
        if let score = result.score, score > 0 {
            parts.append("\(score.formatted(.number)) downloads")
        }
        if let format = result.formatLabel {
            parts.append(format)
        }
        if let language = result.language?.nilIfEmpty {
            parts.append(language)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func badges(for result: PlexSubtitleSearchResult) -> [String] {
        var badges: [String] = []
        if result.isPerfectMatch { badges.append("Perfect Match") }
        if result.isHearingImpaired { badges.append("SDH") }
        if result.isForced { badges.append("Forced") }
        return badges
    }

    private func download(_ result: PlexSubtitleSearchResult) {
        Task {
            if let outcome = await viewModel.download(result) {
                onDownloaded(outcome)
            }
        }
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private func activateDirectionalFocus(_ key: String) -> Bool {
        guard viewModel.downloadingKey == nil,
              let result = viewModel.results.first(where: { $0.key == key }) else {
            return false
        }
        download(result)
        return true
    }
}
#endif

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
    /// Set when Plex never identified the item, so search can offer a match.
    var matchContext: PlayerSubtitleMatchContext?
    let onDownloaded: (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void
    /// Called with refreshed details after the item is matched in Plex.
    var onMatched: (PlexMediaDetails) -> Void = { _ in }
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
    @State private var languageChoice: DuskChoiceConfiguration?
    private let languageTarget = "subtitle-search-language"
    private let retryTarget = "subtitle-search-retry"

    private var directionalTargets: [String] {
        [languageTarget] + (viewModel.errorMessage != nil && viewModel.results.isEmpty ? [retryTarget] : []) +
            viewModel.results.map { "result:" + $0.key } +
            (showsMatchOffer ? viewModel.matchCandidates.map { "match:" + $0.guid } : [])
    }

    /// Called once the downloaded subtitle is on the item and ready to select.
    let onDownloaded: (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void
    private let onMatched: (PlexMediaDetails) -> Void

    init(
        configuration: PlayerSubtitleSearchConfiguration,
        onDownloaded: @escaping (PlayerSubtitleSearchViewModel.DownloadOutcome) -> Void
    ) {
        _viewModel = State(
            initialValue: PlayerSubtitleSearchViewModel(
                plexService: configuration.plexService,
                ratingKey: configuration.ratingKey,
                language: configuration.language,
                knownSubtitleStreamIDs: configuration.knownSubtitleStreamIDs,
                matchContext: configuration.matchContext
            )
        )
        self.onDownloaded = onDownloaded
        self.onMatched = configuration.onMatched
    }

    var body: some View {
        @Bindable var searchViewModel = viewModel

        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(directionalTargets, columnCount: 1)],
            defaultFocus: viewModel.results.first.map { "result:" + $0.key } ?? languageTarget,
            isEnabled: supportsDirectionalSelection && languageChoice == nil && viewModel.actionErrorMessage == nil,
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
                    // Room for the focus ring, which otherwise draws over the
                    // label's first letter.
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.duskSurface)
                    .focusable(!supportsDirectionalSelection)
                    .duskDirectionalFocusHighlight(directionalFocus == languageTarget, shape: RoundedRectangle(cornerRadius: 10))
                    .id(languageTarget)
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
        .modifier(SubtitleSearchFocusScrolling(target: directionalFocus))
        .sheet(item: $languageChoice) { DuskChoiceSheet(configuration: $0) }
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
            .duskDirectionalFocusHighlight(directionalFocus == retryTarget, shape: RoundedRectangle(cornerRadius: 10))
            .id(retryTarget)
        } else if showsMatchOffer {
            matchOffer
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
            supportsDirectionalSelection && directionalFocus == "result:" + result.key,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id("result:" + result.key)
        .listRowBackground(Color.duskSurface)
    }

    // MARK: - Unmatched items

    /// An unmatched item searches empty no matter what, so explain why and
    /// offer the fix instead of the generic "nothing found".
    private var showsMatchOffer: Bool {
        viewModel.isUnmatched && viewModel.results.isEmpty && !viewModel.isLoading
    }

    @ViewBuilder
    private var matchOffer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not Matched in Plex")
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
            Text(matchExplanation)
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)

        if viewModel.isSearchingMatches {
            FeatureLoadingView()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } else {
            ForEach(viewModel.matchCandidates) { candidate in
                matchRow(candidate)
            }
        }
    }

    private var matchExplanation: String {
        let noun = viewModel.matchNoun
        if viewModel.isSearchingMatches {
            return "Subtitle providers find titles by the IDs Plex adds when it identifies a \(noun), and this one has none yet. Looking for a match…"
        }
        if viewModel.matchCandidates.isEmpty {
            let query = viewModel.matchQuery.map { " for “\($0.displayName)”" } ?? ""
            return "Subtitle providers find titles by the IDs Plex adds when it identifies a \(noun). Plex found no match\(query). Use Fix Match on this \(noun) in Plex, or rename its file to just the title and year."
        }
        return "Subtitle providers find titles by the IDs Plex adds when it identifies a \(noun), and this one has none yet. Pick the right \(noun) to match it in Plex and search again."
    }

    private func matchRow(_ candidate: PlexMatchCandidate) -> some View {
        Button {
            applyMatch(candidate)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .foregroundStyle(Color.duskTextPrimary)
                    if let score = candidate.score {
                        Text("\(score)% match")
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                Spacer(minLength: 0)

                if viewModel.matchingGUID == candidate.guid {
                    ProgressView()
                        .tint(Color.duskAccent)
                } else {
                    Text("Match")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskAccent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.matchingGUID != nil)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            supportsDirectionalSelection && directionalFocus == "match:" + candidate.guid,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id("match:" + candidate.guid)
        .listRowBackground(Color.duskSurface)
    }

    private func applyMatch(_ candidate: PlexMatchCandidate) {
        Task {
            if let details = await viewModel.applyMatch(candidate) {
                onMatched(details)
            }
        }
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
        if key == languageTarget {
            let languages = Array(CommonLanguage.allCases)
            languageChoice = DuskChoiceConfiguration(
                title: "Language", options: languages.map(\.displayName),
                selectedIndex: languages.firstIndex(where: { $0.code == viewModel.language }) ?? 0,
                onSelect: { viewModel.language = languages[$0].code }
            )
            return true
        }
        if key == retryTarget {
            Task { await viewModel.load() }
            return true
        }
        if let candidate = viewModel.matchCandidates.first(where: { "match:" + $0.guid == key }) {
            guard viewModel.matchingGUID == nil else { return false }
            applyMatch(candidate)
            return true
        }
        guard viewModel.downloadingKey == nil,
              let result = viewModel.results.first(where: { "result:" + $0.key == key }) else {
            return false
        }
        download(result)
        return true
    }
}
private struct SubtitleSearchFocusScrolling: ViewModifier {
    var target: String?
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: target) { _, target in
                if let target { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .center) } }
            }
        }
    }
}
#endif

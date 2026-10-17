import SwiftUI

#if !os(tvOS)
@MainActor
@Observable
final class SonarrArtworkViewModel {
    private(set) var image: UIImage?
    func load(path: String?, service: SonarrService) async {
        image = nil
        guard let path else { return }
        do {
            let bytes = try await service.imageData(path: path)
            guard !Task.isCancelled else { return }
            image = UIImage(data: bytes)
        } catch { }
    }
}

/// Uses a separate authenticated loader: the Plex image pipeline must never see Sonarr keys.
struct SonarrArtwork: View {
    @Environment(SonarrService.self) private var service
    let path: String?
    @State private var model = SonarrArtworkViewModel()
    var body: some View {
        ZStack {
            Color.duskSurface
            if let image = model.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "tv").foregroundStyle(Color.duskTextSecondary)
            }
        }
        .task(id: "\(service.observationContext):\(path ?? "")") {
            await model.load(path: path, service: service)
        }
    }
}

/// Public preview requests and authenticated Sonarr images use distinct loaders.
/// Disabling Cinemeta Artwork prevents all public still lookups here.
private struct SonarrPreviewArtwork: View {
    @Environment(UserPreferences.self) private var preferences
    let request: CinemetaArtworkRequest?
    let fallbackPath: String?

    var body: some View {
        if preferences.cinemetaArtworkEnabled, let request {
            DuskAsyncImage(url: nil, artworkRequest: request) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: fallback
                case .empty:
                    ZStack {
                        Color.duskSurface
                        ProgressView().tint(Color.duskAccent)
                    }
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View { SonarrArtwork(path: fallbackPath) }
}

struct SonarrSeasonArtwork: View {
    let seasonNumber: Int
    let acquisition: SonarrDetailViewModel
    var body: some View {
        SonarrPreviewArtwork(request: acquisition.seasonArtworkRequest(seasonNumber), fallbackPath: acquisition.seasonPreviewPath(seasonNumber))
    }
}

struct SonarrEpisodeArtwork: View {
    let episode: SonarrEpisode
    let acquisition: SonarrDetailViewModel
    var body: some View {
        SonarrPreviewArtwork(request: acquisition.episodeArtworkRequest(episode), fallbackPath: episode.images?.first?.url)
    }
}

struct SonarrProgressOverlay: View {
    let activity: SonarrActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(activity.title)
                if let fraction = activity.progress {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                } else if ["Searching", "Downloading", "Importing", "Waiting for Plex"].contains(activity.title) {
                    ProgressView().controlSize(.mini).tint(Color.duskAccent)
                }
            }
            .font(.caption.weight(.semibold))
            if let fraction = activity.progress { ProgressView(value: fraction).tint(Color.duskAccent) }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
        .allowsHitTesting(false)
    }
}

struct SonarrMissingEpisodeRow: View {
    let episode: SonarrEpisode
    let acquisition: SonarrDetailViewModel
    var artworkWidth: CGFloat = 220
    var showsInlineSummary = false
    var requestsFocus = false
    var usesDirectionalSelection = false

    var body: some View {
        let activity = acquisition.activity(episode)
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard !activity.blocksRequest else { return }
                Task { await acquisition.acquire(episode: episode) }
            } label: {
                SeasonEpisodeRowLayout(artworkWidth: artworkWidth, summary: episode.overview, showsInlineSummary: showsInlineSummary) {
                    SonarrEpisodeArtwork(episode: episode, acquisition: acquisition)
                        .frame(width: artworkWidth, height: artworkWidth * 9 / 16)
                        .clipped()
                        .opacity(0.42)
                        .overlay(alignment: .bottomLeading) { SonarrProgressOverlay(activity: activity) }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } metadata: {
                    VStack(alignment: .leading, spacing: 6) {
                        SeasonEpisodeTextContent(
                            title: episode.title ?? "Episode \(episode.episodeNumber)", summary: episode.overview,
                            label: "Episode \(episode.episodeNumber)", subtitle: MediaTextFormatter.localizedAirDate(episode.airDate),
                            downloadStatus: nil, isPlayableOffline: false, isUnavailableOffline: false, isWatched: false,
                            isUsingCachedData: false, showsOfflineAvailability: false, showsInlineSummary: showsInlineSummary
                        )
                        if let message = activity.message { Text(message).font(.caption).foregroundStyle(Color.duskTextSecondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            .focusable(!usesDirectionalSelection)
            SeasonEpisodeDivider()
        }
        .duskDirectionalFocusHighlight(requestsFocus, shape: RoundedRectangle(cornerRadius: 20, style: .continuous).inset(by: 8))
        .accessibilityLabel("\(episode.label), \(episode.title ?? "Episode"), \(activity.title)")
        .accessibilityHint(activity.blocksRequest ? "" : "Search and download to your server with Sonarr")
        .contextMenu {
            if activity.title == "Check Sonarr status" {
                Button("Refresh status", systemImage: "arrow.clockwise") { Task { await acquisition.refresh() } }
                Button("Search again in Sonarr", systemImage: "magnifyingglass") { Task { await acquisition.retry(episode: episode) } }
            }
        }
        .disabled((activity.blocksRequest && activity.title != "Check Sonarr status") || acquisition.snapshot?.connectionError != nil)
    }
}

/// Landscape counterpart for the episode detail browser's horizontal shelf.
struct SonarrMissingEpisodeCard: View {
    let episode: SonarrEpisode
    let acquisition: SonarrDetailViewModel
    let width: CGFloat
    var requestsFocus = false
    var usesDirectionalSelection = false

    var body: some View {
        let activity = acquisition.activity(episode)
        Button {
            guard !activity.blocksRequest else { return }
            Task { await acquisition.acquire(episode: episode) }
        } label: {
            VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
                SonarrEpisodeArtwork(episode: episode, acquisition: acquisition)
                    .frame(width: width, height: width * 9 / 16)
                    .clipped()
                    .opacity(0.42)
                    .overlay(alignment: .bottomLeading) { SonarrProgressOverlay(activity: activity) }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .duskDirectionalFocusHighlight(requestsFocus, shape: RoundedRectangle(cornerRadius: 16))
                Text(episode.title ?? "Episode \(episode.episodeNumber)")
                    .font(usesDirectionalSelection ? .headline : DuskPosterMetrics.titleFont)
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2, reservesSpace: usesDirectionalSelection)
                if usesDirectionalSelection, let summary = episode.overview, !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(3, reservesSpace: true)
                }
                Text(episode.label).font(.subheadline).foregroundStyle(Color.duskTextSecondary)
                if let message = activity.message ?? episode.airDate {
                    Text(message).font(.footnote).foregroundStyle(Color.duskTextSecondary).lineLimit(3)
                }
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(!usesDirectionalSelection)
        .contextMenu {
            if activity.title == "Check Sonarr status" {
                Button("Refresh status", systemImage: "arrow.clockwise") { Task { await acquisition.refresh() } }
                Button("Search again in Sonarr", systemImage: "magnifyingglass") { Task { await acquisition.retry(episode: episode) } }
            }
        }
        .disabled((activity.blocksRequest && activity.title != "Check Sonarr status") || acquisition.snapshot?.connectionError != nil)
        .accessibilityLabel("\(episode.label), \(episode.title ?? "Episode"), \(activity.title)")
        .accessibilityHint(activity.blocksRequest ? "" : "Search and download to your server with Sonarr")
        .accessibilityAddTraits(requestsFocus ? [.isSelected] : [])
    }
}

struct SonarrSeasonCard: View {
    let season: SonarrSeason
    let acquisition: SonarrDetailViewModel
    let width: CGFloat
    var requestsFocus = false
    var usesDirectionalSelection = false

    var body: some View {
        let plex = acquisition.snapshot?.seasons.first { $0.index == season.seasonNumber }
        let activity = acquisition.activity(season: season.seasonNumber)
        NavigationLink(value: AppNavigationRoute.sonarrSeason(showKey: acquisition.showKey ?? "", seasonNumber: season.seasonNumber)) {
            VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
                SonarrSeasonArtwork(seasonNumber: season.seasonNumber, acquisition: acquisition)
                    .frame(width: width, height: width * 1.5)
                    .clipped()
                    .opacity(plex == nil ? 0.42 : 1)
                    .overlay(alignment: .bottomLeading) {
                        if let activity { SonarrProgressOverlay(activity: activity) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                PosterCardText(title: season.seasonNumber == 0 ? "Specials" : "Season \(season.seasonNumber)", subtitle: activity?.message, width: width)
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
            .overlay {
                if requestsFocus { RoundedRectangle(cornerRadius: 16).stroke(Color.primary, lineWidth: 2).allowsHitTesting(false) }
            }
        }
        .buttonStyle(.plain)
        .focusable(!usesDirectionalSelection)
        .contextMenu {
            Button("Download season", systemImage: "arrow.down.circle") {
                Task { await acquisition.acquire(season: season.seasonNumber) }
            }
            .disabled(activity?.blocksRequest == true || acquisition.snapshot?.connectionError != nil)
        }
    }
}

/// A quiet shelf-header affordance; diagnostics never occupy the browsing layout.
struct SonarrDownloadStatusButton: View {
    let acquisition: SonarrDetailViewModel
    var requestsFocus = false
    var usesDirectionalSelection = false
    let onOpen: () -> Void

    var body: some View {
        if let issue = acquisition.downloadIssue {
            Button(action: onOpen) {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(!usesDirectionalSelection)
            .duskDirectionalFocusHighlight(requestsFocus, shape: Circle())
            .accessibilityLabel("Download information: \(issue.title)")
            .help(issue.summary)
        }
    }
}

private struct SonarrDownloadStatusView: View {
    @Environment(\.dismiss) private var dismiss
    let acquisition: SonarrDetailViewModel
    @State private var showsTechnicalDetails = false
    @State private var isRefreshing = false
    @State private var focused: Target?
    private enum Target: Hashable { case refresh, technical }
    private var usesDirectional: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    var body: some View {
        DuskPanelContent {
            DuskDirectionalFocusScope(
                focusedID: $focused,
                groups: [.grid(acquisition.downloadIssue == nil ? [.refresh] : [.refresh, .technical], columnCount: 1)],
                defaultFocus: .refresh,
                isEnabled: usesDirectional,
                onActivate: activate,
                onBack: { dismiss(); return true }
            ) {
                List {
                    if let issue = acquisition.downloadIssue {
                        Section(issue.title) { Text(issue.summary).foregroundStyle(Color.duskTextSecondary) }
                            .listRowBackground(Color.duskSurface)
                    } else {
                        Section { Text("No download issues to report.").foregroundStyle(Color.duskTextSecondary) }
                            .listRowBackground(Color.duskSurface)
                    }
                    Section {
                        Button { refresh() } label: {
                            HStack {
                                Label("Refresh download status", systemImage: "arrow.clockwise")
                                Spacer()
                                if isRefreshing { ProgressView().tint(Color.duskAccent) }
                            }
                        }
                        .disabled(isRefreshing)
                        .focusable(!usesDirectional)
                        .duskDirectionalFocusHighlight(focused == .refresh, shape: RoundedRectangle(cornerRadius: 12))
                        if let issue = acquisition.downloadIssue {
                            Button(showsTechnicalDetails ? "Hide technical details" : "Technical details", systemImage: "chevron.right") {
                                showsTechnicalDetails.toggle()
                            }
                            .focusable(!usesDirectional)
                            .duskDirectionalFocusHighlight(focused == .technical, shape: RoundedRectangle(cornerRadius: 12))
                            if showsTechnicalDetails { Text(issue.technicalDetails).font(.footnote).foregroundStyle(Color.duskTextSecondary).textSelection(.enabled) }
                        }
                    }
                    .listRowBackground(Color.duskSurface)
                }
                .duskScrollContentBackgroundHidden()
                .background(Color.duskBackground)
            }
            .duskNavigationTitle("Download Information")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func activate(_ target: Target) -> Bool {
        switch target {
        case .refresh:
            guard !isRefreshing else { return false }
            refresh()
        case .technical:
            guard acquisition.downloadIssue != nil else { return false }
            showsTechnicalDetails.toggle()
        }
        return true
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { await acquisition.refresh(); isRefreshing = false }
    }
}

extension View {
    func duskSonarrDownloadStatus(acquisition: SonarrDetailViewModel, isPresented: Binding<Bool>) -> some View {
        duskNavigationPanel(isPresented: isPresented) { SonarrDownloadStatusView(acquisition: acquisition) }
    }
}
#endif

import SwiftUI

/// Actual Plex audio streams, never the show's original language or subtitle tracks.
struct PlexAudioLanguages: Sendable {
    let names: [String]
    let hasEnglish: Bool
    let hasUnknown: Bool

    init(media: [PlexMedia]) {
        let available = media.filter(\.hasAvailablePart)
        let parts = available.flatMap(\.parts).filter { $0.accessible != false && $0.exists != false }
        let tracks = parts.flatMap(\.streams).filter { $0.streamType == .audio }
        var names = Set<String>()
        var english = false
        var unknown = tracks.isEmpty || parts.contains { !$0.streams.contains { $0.streamType == .audio } }
        for track in tracks {
            let raw = ([track.languageTag, track.languageCode].compactMap { $0 }.first { !$0.isEmpty } ?? "").lowercased()
            let code = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            let name = track.language?.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["en", "eng"].contains(code) || name?.lowercased() == "english" { english = true }
            if !code.isEmpty && !["und", "unknown", "mul", "zxx"].contains(code) {
                names.insert(Locale.current.localizedString(forLanguageCode: code) ?? name ?? code.uppercased())
            } else if let name, !name.isEmpty, !["unknown", "undetermined"].contains(name.lowercased()) {
                names.insert(name)
            } else { unknown = true }
        }
        self.names = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.hasEnglish = english
        self.hasUnknown = unknown
    }

    var text: String {
        let languages = names + (hasUnknown ? ["Unknown"] : [])
        let summary = languages.isEmpty ? "Unknown" : languages.joined(separator: ", ")
        return "Audio: \(summary)" + (!hasEnglish && !hasUnknown ? " · No English" : "")
    }
}

@MainActor @Observable
private final class PlexAudioLanguageViewModel {
    private(set) var summary: PlexAudioLanguages?
    func load(ratingKey: String, offlineOnly: Bool, plex: PlexService, downloads: DownloadManager) async {
        summary = nil
        if let cached = downloads.cachedMediaDetails(ratingKey: ratingKey) {
            summary = PlexAudioLanguages(media: cached.media)
        }
        guard !offlineOnly, plex.isConnected else { return }
        let server = plex.currentServerIdentifier
        let profile = plex.activeProfileID
        do {
            let details = try await plex.getMediaDetails(ratingKey: ratingKey)
            guard !Task.isCancelled, server == plex.currentServerIdentifier, profile == plex.activeProfileID else { return }
            summary = PlexAudioLanguages(media: details.media)
        } catch { }
    }
}

/// Shelf metadata is fetched only for mounted visible cards; never scan a whole library.
struct PlexAudioLanguageBadge: View {
    @Environment(PlexService.self) private var plex
    @Environment(DownloadManager.self) private var downloads
    @State private var model = PlexAudioLanguageViewModel()
    var media: [PlexMedia]? = nil
    var ratingKey: String? = nil
    var offlineOnly = false
    var showsEnglish = false

    var body: some View {
        let summary = media.map(PlexAudioLanguages.init(media:)) ?? model.summary
        Group {
            if let summary, showsEnglish || !summary.hasEnglish {
                Label(summary.text, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(summary.text)
            }
        }
        .task(id: "\(plex.currentServerIdentifier ?? ""):\(plex.activeProfileID ?? ""):\(plex.metadataRevision):\(ratingKey ?? ""):\(offlineOnly)") {
            guard media == nil, let ratingKey else { return }
            await model.load(ratingKey: ratingKey, offlineOnly: offlineOnly, plex: plex, downloads: downloads)
        }
    }
}

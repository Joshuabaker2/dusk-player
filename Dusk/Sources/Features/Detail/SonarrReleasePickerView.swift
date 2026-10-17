import SwiftUI

@MainActor @Observable
private final class SonarrReleasePickerViewModel {
    private(set) var search: SonarrReleaseSearch?
    private(set) var episodeSelection: SonarrEpisodeSelectionRequired?
    private(set) var isLoading = true
    private(set) var isSubmitting = false
    private(set) var submittedTitle: String?
    private(set) var error: String?
    var englishOnly = false
    private var service: SonarrService?

    var episodeChoices: [SonarrEpisode] {
        (episodeSelection?.episodes ?? []).sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
    }

    var releases: [SonarrRelease] {
        (search?.releases ?? []).filter { !englishOnly || $0.isReportedEnglish }
    }
    var activity: SonarrActivity? {
        guard let search else { return nil }
        return service?.replacementActivity(episodeID: search.episodeID, showKey: search.showKey)
    }
    func load(ratingKey: String, service: SonarrService, confirmedEpisodeID: Int? = nil, confirmationContext: String? = nil) async {
        self.service = service
        isLoading = true
        error = nil
        search = nil
        episodeSelection = nil
        submittedTitle = nil
        defer { isLoading = false }
        do { search = try await service.searchAlternativeReleases(ratingKey: ratingKey, confirmedEpisodeID: confirmedEpisodeID, confirmationContext: confirmationContext) }
        catch let selection as SonarrEpisodeSelectionRequired { episodeSelection = selection }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func chooseEpisode(_ episodeID: Int, ratingKey: String, service: SonarrService) async {
        guard let selection = episodeSelection, selection.episodes.contains(where: { $0.id == episodeID }) else { return }
        await load(ratingKey: ratingKey, service: service, confirmedEpisodeID: episodeID, confirmationContext: selection.context)
    }

    func isCurrent(_ release: SonarrRelease) -> Bool {
        guard let title = search?.currentReleaseTitle, !title.isEmpty else { return false }
        func normalized(_ name: String) -> String {
            var name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [".mkv", ".mp4", ".m4v", ".avi", ".ts"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
            return name
        }
        return normalized(title) == normalized(release.title)
    }
    func canGrab(_ release: SonarrRelease) -> Bool {
        guard let search, !isSubmitting, submittedTitle == nil, !isCurrent(release),
              release.guid?.isEmpty == false, release.downloadAllowed != false,
              release.mappedSeriesId == search.seriesID,
              release.mappedEpisodeInfo?.contains(where: { $0.id == search.episodeID }) == true else { return false }
        return activity?.blocksRequest != true
    }
    func grab(_ release: SonarrRelease) async {
        guard canGrab(release), let search, let service else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            try await service.grabAlternative(release, search: search)
            submittedTitle = release.title
        } catch { self.error = error.localizedDescription }
    }
}

#if !os(tvOS)
struct SonarrReleasePickerView: View {
    @Environment(SonarrService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var model = SonarrReleasePickerViewModel()
    @State private var focused: Target?
    let ratingKey: String

    private enum Target: Hashable { case filter, refresh, episode(Int), release(String) }
    private var usesDirectional: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
    private var targets: [Target] {
        if model.episodeSelection != nil { return [.refresh] + model.episodeChoices.map { .episode($0.id) } }
        return [.filter, .refresh] + model.releases.filter(model.canGrab).map { .release($0.id) }
    }

    var body: some View {
        DuskPanelContent {
            DuskDirectionalFocusScope(
                focusedID: $focused,
                groups: [.grid(targets, columnCount: 1)],
                defaultFocus: targets.first,
                isEnabled: usesDirectional,
                onActivate: activate,
                onBack: { dismiss(); return true }
            ) {
                content
            }
            .duskNavigationTitle("Download a Different File")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: service.observationContext) { await model.load(ratingKey: ratingKey, service: service) }
        .onChange(of: model.episodeSelection?.plexEpisodeLabel) { _, _ in
            guard let selection = model.episodeSelection else { return }
            if let id = selection.suggestedEpisodeID ?? model.episodeChoices.first?.id { focused = .episode(id) }
        }
        .task(id: model.search?.showKey) {
            guard let key = model.search?.showKey else { return }
            await service.observe(showKey: key)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            FeatureLoadingView()
        } else {
            ScrollViewReader { proxy in
                List {
                    Section {
                        if model.episodeSelection == nil {
                            Button {
                                model.englishOnly.toggle()
                            } label: {
                                HStack {
                                    Text("Reported English only")
                                    Spacer()
                                    Image(systemName: model.englishOnly ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable(!usesDirectional)
                            .duskDirectionalFocusHighlight(focused == .filter, shape: RoundedRectangle(cornerRadius: 12))
                            .accessibilityValue(model.englishOnly ? "On" : "Off")
                            .id(Target.filter)
                        }
                        Button("Refresh release search", systemImage: "arrow.clockwise") {
                            Task { await model.load(ratingKey: ratingKey, service: service) }
                        }
                        .disabled(model.isSubmitting)
                        .focusable(!usesDirectional)
                        .duskDirectionalFocusHighlight(focused == .refresh, shape: RoundedRectangle(cornerRadius: 12))
                        .id(Target.refresh)
                    } footer: {
                        if model.episodeSelection != nil {
                            Text("No release search has run yet. Choose the corresponding Sonarr episode below.")
                        } else {
                            Text("Listed in Sonarr's rank order, including rejected releases and their reasons. Language labels come from release metadata, not inspected audio tracks. Dub/Dual/Multi in a title is only a hint. Sonarr handles importing and replacing the current file; Dusk does not delete it.")
                        }
                    }
                    .listRowBackground(Color.duskSurface)

                    if let selection = model.episodeSelection {
                        Section("Choose the matching episode in Sonarr") {
                            Text("Plex: \(selection.plexEpisodeLabel)").font(.subheadline)
                            Text("Episode numbering or titles differ. Choose the corresponding episode in \(selection.seriesTitle) to search its releases. This choice applies only to this replacement.")
                                .font(.footnote).foregroundStyle(Color.duskTextSecondary)
                            ForEach(model.episodeChoices) { episode in
                                Button {
                                    Task { await model.chooseEpisode(episode.id, ratingKey: ratingKey, service: service) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(episode.label) · \(episode.title ?? "Episode")").foregroundStyle(Color.duskTextPrimary)
                                        if let date = episode.airDate { Text(date).font(.caption).foregroundStyle(Color.duskTextSecondary) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusable(!usesDirectional)
                                .duskDirectionalFocusHighlight(focused == .episode(episode.id), shape: RoundedRectangle(cornerRadius: 12))
                                .id(Target.episode(episode.id))
                            }
                        }
                        .listRowBackground(Color.duskSurface)
                    }
                    if let search = model.search {
                        Section {
                            Text("Sonarr episode: \(search.episodeLabel)").font(.subheadline)
                        }
                        .listRowBackground(Color.duskSurface)
                    }
                    if let error = model.error {
                        Section { Text(error).font(.footnote).foregroundStyle(Color.duskTextSecondary) }
                            .listRowBackground(Color.duskSurface)
                    }
                    if model.submittedTitle != nil || model.activity != nil {
                        Section("Replacement") {
                            if let title = model.submittedTitle { Text(title).font(.subheadline) }
                            if let activity = model.activity {
                                SonarrProgressOverlay(activity: activity)
                                if let message = activity.message { Text(message).font(.footnote) }
                            }
                        }
                        .listRowBackground(Color.duskSurface)
                    }
                    if model.error == nil, model.episodeSelection == nil, model.releases.isEmpty {
                        Section { Text(model.englishOnly ? "No releases report English. Turn off the filter to inspect dub/dual titles or unknown languages." : "Sonarr found no alternate releases.").foregroundStyle(Color.duskTextSecondary) }
                            .listRowBackground(Color.duskSurface)
                    }
                    ForEach(model.releases) { release in
                        Button {
                            Task { await model.grab(release) }
                        } label: {
                            releaseLabel(release)
                        }
                        .buttonStyle(.plain)
                        .focusable(!usesDirectional)
                        .disabled(!model.canGrab(release))
                        .duskDirectionalFocusHighlight(focused == .release(release.id), shape: RoundedRectangle(cornerRadius: 12))
                        .listRowBackground(Color.duskSurface)
                        .id(Target.release(release.id))
                    }
                }
                .duskScrollContentBackgroundHidden()
                .background(Color.duskBackground)
                .onChange(of: focused) { _, target in
                    if let target { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    private func releaseLabel(_ release: SonarrRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let index = model.search?.releases.firstIndex(where: { $0.id == release.id }) {
                Text("Sonarr #\(index + 1)" + (model.isCurrent(release) ? " · Current file" : ""))
                    .font(.caption).foregroundStyle(Color.duskTextSecondary)
            }
            Text(release.title).font(.headline).foregroundStyle(Color.duskTextPrimary).lineLimit(4)
            Text(release.languageText).font(.subheadline).foregroundStyle(Color.duskTextSecondary)
            if release.titleHintsDub { Text("Dub / Dual / Multi title hint — audio unverified").font(.caption).foregroundStyle(Color.duskTextSecondary) }
            Text([release.quality?.quality?.name, release.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }, release.indexer,
                  release.customFormatScore.map { "Score \($0)" }, release.seeders.map { "\($0) seeders" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Color.duskTextSecondary)
            if release.fullSeason == true { Text("Season pack — may include other episodes").font(.caption).foregroundStyle(Color.duskTextSecondary) }
            if let reasons = release.rejections, !reasons.isEmpty {
                Text("Sonarr: \(reasons.joined(separator: "; "))").font(.caption).foregroundStyle(Color.duskTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func activate(_ target: Target) -> Bool {
        switch target {
        case .filter: model.englishOnly.toggle()
        case .refresh:
            guard !model.isSubmitting else { return false }
            Task { await model.load(ratingKey: ratingKey, service: service) }
        case .episode(let id):
            guard model.episodeSelection?.episodes.contains(where: { $0.id == id }) == true else { return false }
            Task { await model.chooseEpisode(id, ratingKey: ratingKey, service: service) }
        case .release(let id):
            guard let release = model.releases.first(where: { $0.id == id }), model.canGrab(release) else { return false }
            Task { await model.grab(release) }
        }
        return true
    }
}
#endif

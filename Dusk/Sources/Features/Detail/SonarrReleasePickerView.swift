import SwiftUI

@MainActor @Observable
private final class SonarrReleasePickerViewModel {
    private(set) var search: SonarrReleaseSearch?
    private(set) var episodeSelection: SonarrEpisodeSelectionRequired?
    private(set) var isLoading = true
    private(set) var isSearchingPacks = false
    private(set) var isSubmitting = false
    private(set) var submittedTitle: String?
    private(set) var error: String?
    private(set) var packError: String?
    private(set) var audioHints: [SonarrRelease.ID: [String]] = [:]
    private(set) var englishAudioOnly = false
    private var filterWasChosen = false
    private var loadID = 0
    private var service: SonarrService?

    var episodeChoices: [SonarrEpisode] {
        (episodeSelection?.episodes ?? []).sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
    }

    var releases: [SonarrRelease] {
        (search?.allReleases ?? []).filter { !englishAudioOnly || hasEnglishAudioHint($0) }
    }
    var canSearchPacks: Bool { search != nil && search?.seasonPackReleases == nil && !isSearchingPacks && !isSubmitting }
    var activity: SonarrActivity? {
        guard let search else { return nil }
        return service?.replacementActivity(episodeID: search.episodeID, showKey: search.showKey)
    }
    func toggleEnglishAudio() {
        englishAudioOnly.toggle()
        filterWasChosen = true
    }
    func hasEnglishAudioHint(_ release: SonarrRelease) -> Bool {
        release.isReportedEnglish || audioHints[release.id]?.isEmpty == false
    }
    func load(ratingKey: String, service: SonarrService, confirmedEpisodeID: Int? = nil, confirmationContext: String? = nil) async {
        self.service = service
        loadID += 1
        isLoading = true
        error = nil
        packError = nil
        search = nil
        episodeSelection = nil
        submittedTitle = nil
        do { setSearch(try await service.searchAlternativeReleases(ratingKey: ratingKey, confirmedEpisodeID: confirmedEpisodeID, confirmationContext: confirmationContext)) }
        catch let selection as SonarrEpisodeSelectionRequired { episodeSelection = selection }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        isLoading = false
        // Japanese-original shows often have dual audio only in season batches; look there before reporting nothing.
        if let search, search.prefersEnglishAudio, englishAudioOnly, releases.isEmpty { await searchPacks() }
    }
    func searchPacks() async {
        guard canSearchPacks, let search, let service else { return }
        let id = loadID
        isSearchingPacks = true
        packError = nil
        defer { isSearchingPacks = false }
        do {
            let updated = try await service.searchSeasonPacks(for: search)
            // A refresh or episode choice during the slower season search replaces the search it extended.
            guard id == loadID else { return }
            setSearch(updated)
        } catch { if !Task.isCancelled, id == loadID { packError = error.localizedDescription } }
    }
    private func setSearch(_ value: SonarrReleaseSearch) {
        search = value
        audioHints = Dictionary(value.allReleases.map { ($0.id, $0.englishAudioHints) }, uniquingKeysWith: { first, _ in first })
        if !filterWasChosen { englishAudioOnly = value.prefersEnglishAudio }
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

    private enum Target: Hashable { case filter, refresh, seasonPacks, episode(Int), release(String) }
    private var usesDirectional: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
    private var targets: [Target] {
        if model.episodeSelection != nil { return [.refresh] + model.episodeChoices.map { .episode($0.id) } }
        return [.filter, .refresh] + (model.canSearchPacks ? [.seasonPacks] : []) + model.releases.filter(model.canGrab).map { .release($0.id) }
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
                                model.toggleEnglishAudio()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("English audio only")
                                        Text("Dub or dual audio in the title or custom formats, or English reported by Sonarr")
                                            .font(.caption).foregroundStyle(Color.duskTextSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: model.englishAudioOnly ? "checkmark.circle.fill" : "circle")
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(!usesDirectional)
                            .duskDirectionalFocusHighlight(focused == .filter, shape: RoundedRectangle(cornerRadius: 12))
                            .accessibilityValue(model.englishAudioOnly ? "On" : "Off")
                            .id(Target.filter)
                        }
                        Button("Refresh release search", systemImage: "arrow.clockwise") {
                            Task { await model.load(ratingKey: ratingKey, service: service) }
                        }
                        .disabled(model.isSubmitting)
                        .focusable(!usesDirectional)
                        .duskDirectionalFocusHighlight(focused == .refresh, shape: RoundedRectangle(cornerRadius: 12))
                        .id(Target.refresh)
                        if model.isSearchingPacks {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching season packs…").foregroundStyle(Color.duskTextSecondary)
                            }
                        } else if let packs = model.search?.seasonPackReleases {
                            Text(packs.isEmpty ? "No season packs include this episode." : "\(packs.count) season-search \(packs.count == 1 ? "release includes" : "releases include") this episode.")
                                .font(.footnote).foregroundStyle(Color.duskTextSecondary)
                        } else if model.search != nil {
                            Button("Search season packs", systemImage: "square.stack.3d.up") {
                                Task { await model.searchPacks() }
                            }
                            .disabled(!model.canSearchPacks)
                            .focusable(!usesDirectional)
                            .duskDirectionalFocusHighlight(focused == .seasonPacks, shape: RoundedRectangle(cornerRadius: 12))
                            .id(Target.seasonPacks)
                        }
                    } footer: {
                        if model.episodeSelection != nil {
                            Text("No release search has run yet. Choose the corresponding Sonarr episode below.")
                        } else {
                            Text("Listed in Sonarr's rank order, including rejected releases and their reasons. Language and dub/dual-audio labels come from release names and Sonarr metadata, not inspected audio tracks. Dual-audio anime is often released as season packs, which a season search can find (it may take a while). Sonarr handles importing and replacing the current file; Dusk does not delete it.")
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
                    if let error = model.packError {
                        Section { Text("Season pack search failed: \(error)").font(.footnote).foregroundStyle(Color.duskTextSecondary) }
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
                    if model.error == nil, model.episodeSelection == nil, !model.isSearchingPacks, model.releases.isEmpty {
                        Section { Text(emptyMessage).foregroundStyle(Color.duskTextSecondary) }
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
            if let rank = rankLabel(release) {
                Text(rank + (model.isCurrent(release) ? " · Current file" : ""))
                    .font(.caption).foregroundStyle(Color.duskTextSecondary)
            }
            Text(release.title).font(.headline).foregroundStyle(Color.duskTextPrimary).lineLimit(4)
            Text(release.languageText).font(.subheadline).foregroundStyle(Color.duskTextSecondary)
            if let hints = model.audioHints[release.id], !hints.isEmpty {
                Text(hints.joined(separator: " · ") + " — audio unverified").font(.caption).foregroundStyle(Color.duskTextSecondary)
            }
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

    private var emptyMessage: String {
        guard model.englishAudioOnly else { return "Sonarr found no alternate releases." }
        let packs = model.search?.seasonPackReleases == nil ? " Search season packs, or turn" : " Turn"
        return "No releases look like English audio." + packs + " off the filter to inspect unknown languages."
    }

    /// Episode and season searches each keep Sonarr's own rank order.
    private func rankLabel(_ release: SonarrRelease) -> String? {
        if let index = model.search?.releases.firstIndex(where: { $0.id == release.id }) { return "Sonarr #\(index + 1)" }
        if let index = model.search?.seasonPackReleases?.firstIndex(where: { $0.id == release.id }) { return "Season search #\(index + 1)" }
        return nil
    }

    private func activate(_ target: Target) -> Bool {
        switch target {
        case .filter: model.toggleEnglishAudio()
        case .refresh:
            guard !model.isSubmitting else { return false }
            Task { await model.load(ratingKey: ratingKey, service: service) }
        case .seasonPacks:
            guard model.canSearchPacks else { return false }
            Task { await model.searchPacks() }
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

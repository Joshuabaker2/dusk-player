import Foundation

/// Cached library order for the current (server, Plex Home profile) pair.
///
/// Holds the connected server's `/library/sections` list and the account's
/// `pinnedSources` list from plex.tv, and combines them into the effective
/// order every screen in Dusk uses. `PlexService+LibraryOrder` owns all
/// networking and is the only thing allowed to mutate the store; everything
/// else reads `orderedSections` / `orderedSectionKeys`.
///
/// The cache is keyed by `"<serverID>|<profileID>"` because the pinned list is
/// per Plex account *token*: Plex Home members each have their own, and the
/// section keys only mean anything for one server.
@MainActor
@Observable
final class LibraryOrderStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// `/library/sections` in the server's own order, unfiltered — music and
    /// photo sections are kept even though Dusk cannot browse them, because
    /// Home hub regrouping and the write path both need every section.
    private(set) var sections: [PlexLibrary] = []

    /// The account's complete pinned list: every server plus the cloud
    /// providers, exactly as plex.tv returned it. Never filtered down to the
    /// connected server — the entries of other sources have to survive a write.
    private(set) var pinnedSources: [PlexPinnedSource] = []

    private(set) var state: State = .idle

    /// True when the plex.tv `experience` blob could not be read (transport or
    /// auth failure). A missing or unparseable setting is *not* a failure: that
    /// just means the account never customized its order.
    private(set) var orderUnavailable = false

    /// Machine identifier of the server the cached data belongs to.
    private(set) var machineIdentifier: String?

    /// `"<serverID>|<profileID>"` of the cached data.
    private(set) var cacheIdentity: String?

    /// The whole decoded `experience` blob, kept so a write can preserve every
    /// key Dusk does not model. nil means "the account has no experience
    /// setting yet"; the first write then creates one.
    @ObservationIgnored private(set) var experienceBlob: DuskJSONValue?

    /// In-flight combined load, so concurrent callers (Home, Libraries, the
    /// settings screen, all racing at launch) share one pair of requests.
    @ObservationIgnored var loadTask: Task<[PlexLibrary], Error>?

    /// Tail of the write chain. Writes are last-writer-wins on plex.tv, so they
    /// are serialized locally and each one re-reads before it posts.
    @ObservationIgnored var writeTask: Task<Void, Error>?

    /// The order Dusk shows: pinned sections of the connected server first, then
    /// everything else in server order. See `LibraryOrderArrangement`.
    var orderedSections: [PlexLibrary] {
        LibraryOrderArrangement.effectiveOrder(
            libraries: sections,
            pinnedSources: pinnedSources,
            machineIdentifier: machineIdentifier
        )
    }

    var orderedSectionKeys: [String] {
        orderedSections.map(\.key)
    }

    /// Drops everything cached. Called whenever the connected server or the
    /// active profile changes, so a stale order can never leak across accounts.
    func invalidate() {
        loadTask?.cancel()
        loadTask = nil
        sections = []
        pinnedSources = []
        experienceBlob = nil
        machineIdentifier = nil
        cacheIdentity = nil
        orderUnavailable = false
        state = .idle
    }

    // MARK: - Mutation (PlexService+LibraryOrder only)

    func matchesCacheIdentity(_ identity: String) -> Bool {
        cacheIdentity == identity
    }

    func beginLoading() {
        state = .loading
    }

    func failLoading(_ message: String) {
        state = .failed(message)
    }

    /// Commits a completed combined load.
    func apply(
        sections: [PlexLibrary],
        experience: PlexExperienceSettings?,
        machineIdentifier: String?,
        identity: String
    ) {
        self.sections = sections
        self.machineIdentifier = machineIdentifier
        cacheIdentity = identity
        if let experience {
            pinnedSources = experience.pinnedSources
            experienceBlob = experience.blob
            orderUnavailable = false
        } else {
            pinnedSources = []
            experienceBlob = nil
            orderUnavailable = true
        }
        state = .loaded
    }

    /// Commits a blob-only refresh, leaving `sections` alone.
    func apply(experience: PlexExperienceSettings, identity: String) {
        pinnedSources = experience.pinnedSources
        experienceBlob = experience.blob
        orderUnavailable = false
        cacheIdentity = identity
        if state != .loaded, !sections.isEmpty {
            state = .loaded
        }
    }

    /// Commits the exact payload that plex.tv just accepted, so the UI settles
    /// on the written order without another round trip.
    func commitWrite(pinnedSources: [PlexPinnedSource], blob: DuskJSONValue) {
        self.pinnedSources = pinnedSources
        experienceBlob = blob
        orderUnavailable = false
    }

    func clearLoadTask(_ task: Task<[PlexLibrary], Error>) {
        if loadTask == task {
            loadTask = nil
        }
    }

    func clearWriteTask(_ task: Task<Void, Error>) {
        if writeTask == task {
            writeTask = nil
        }
    }
}

/// The parsed plex.tv `experience` setting.
struct PlexExperienceSettings: Sendable {
    /// The whole blob, or nil when the account has no `experience` setting yet
    /// (or it was unparseable — both mean "never customized").
    var blob: DuskJSONValue?
    /// `sidebarSettings.pinnedSources`, in sidebar order.
    var pinnedSources: [PlexPinnedSource]

    static let neverCustomized = PlexExperienceSettings(blob: nil, pinnedSources: [])
}

import SwiftUI

struct MediaVersionPickerRequest {
    let ratingKey: String
    let resumeOffsetMilliseconds: Int?
    let placeholder: PlaybackPlaceholder
    var offlineOnly = false

    init(details: PlexMediaDetails, offlineOnly: Bool) {
        ratingKey = details.ratingKey
        resumeOffsetMilliseconds = details.viewOffset
        placeholder = PlaybackPlaceholder(details: details)
        self.offlineOnly = offlineOnly
    }

    init(episode: PlexEpisode, offlineOnly: Bool) {
        ratingKey = episode.ratingKey
        resumeOffsetMilliseconds = episode.viewOffset
        placeholder = PlaybackPlaceholder(episode: episode)
        self.offlineOnly = offlineOnly
    }
}

@MainActor @Observable
private final class MediaVersionPickerViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager
    private let request: MediaVersionPickerRequest
    private(set) var versions: [PlexMedia] = []
    private(set) var isLoading = true
    private(set) var error: String?

    init(request: MediaVersionPickerRequest, plexService: PlexService, downloadManager: DownloadManager) {
        self.request = request
        self.plexService = plexService
        self.downloadManager = downloadManager
    }

    func load() async {
        isLoading = true
        error = nil
        versions = []
        defer { isLoading = false }

        var offlineOnly = request.offlineOnly || !plexService.isConnected
        let details: PlexMediaDetails
        if offlineOnly {
            guard let cached = downloadManager.cachedMediaDetails(ratingKey: request.ratingKey) else {
                versions = []
                return
            }
            details = cached
        } else {
            do {
                details = try await plexService.getMediaDetails(ratingKey: request.ratingKey, checkFiles: true)
            } catch {
                guard !Task.isCancelled else { return }
                guard downloadManager.isPlayableOffline(ratingKey: request.ratingKey),
                      let cached = downloadManager.cachedMediaDetails(ratingKey: request.ratingKey) else {
                    let message = error.localizedDescription
                    self.error = AuthenticationFailure.requiresReauthentication(message: message)
                        ? message : "Couldn't load files. Try again."
                    return
                }
                details = cached
                offlineOnly = true
            }
        }
        guard !Task.isCancelled else { return }

        if offlineOnly {
            guard downloadManager.isPlayableOffline(ratingKey: request.ratingKey) else { return }
            let downloaded = downloadManager.downloadedMediaVersion(for: request.ratingKey, in: details)
            versions = downloaded.map { [$0.media] } ?? []
        } else {
            let downloadedID = downloadManager.isPlayableOffline(ratingKey: request.ratingKey)
                ? downloadManager.downloadedMediaVersion(for: request.ratingKey, in: details)?.media.id : nil
            versions = details.media.filter { $0.hasAvailablePart || $0.id == downloadedID }
        }
    }

    func retry() async {
        if let error, AuthenticationFailure.requiresReauthentication(message: error) {
            AuthenticationFailure.beginReauthentication(plexService: plexService)
        } else {
            await load()
        }
    }
}

struct MediaVersionPickerView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MediaVersionPickerViewModel
    @State private var focusedTarget: FocusTarget?
    let request: MediaVersionPickerRequest

    init(request: MediaVersionPickerRequest, plexService: PlexService, downloadManager: DownloadManager) {
        self.request = request
        _viewModel = State(initialValue: MediaVersionPickerViewModel(
            request: request, plexService: plexService, downloadManager: downloadManager
        ))
    }

    private enum FocusTarget: Hashable {
        case version(Int)
        case retry
    }

    private var focusTargets: [FocusTarget] {
        viewModel.error == nil ? viewModel.versions.map { .version($0.id) } : [.retry]
    }

    private var defaultFocus: FocusTarget? {
        if viewModel.error != nil { return .retry }
        return StreamResolver.selectMediaVersion(
            from: viewModel.versions,
            preferredMaxResolution: preferences.maxResolution
        ).map { .version($0.id) }
    }

    private var usesDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    var body: some View {
        DuskPanelContent {
            DuskDirectionalFocusScope(
                focusedID: $focusedTarget,
                groups: [.grid(focusTargets, columnCount: 1)],
                defaultFocus: defaultFocus,
                isEnabled: usesDirectionalSelection,
                onActivate: activate,
                onBack: { dismiss(); return true }
            ) {
                content
            }
            .duskNavigationTitle("Select File")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            FeatureLoadingView()
        } else if let error = viewModel.error {
            FeatureErrorView(message: error) {
                Task { await viewModel.retry() }
            }
            .duskDirectionalFocusHighlight(focusedTarget == .retry, shape: RoundedRectangle(cornerRadius: 16))
        } else if viewModel.versions.isEmpty {
            FeatureEmptyStateView(systemImage: "doc", title: "No Available Files")
        } else {
            ScrollViewReader { proxy in
                List(viewModel.versions) { version in
                    Button { _ = select(version.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(MediaTextFormatter.playbackVersionMenuLabel(version))
                                .font(.headline)
                                .foregroundStyle(Color.duskTextPrimary)
                            if let filename = version.firstAvailablePart?.file?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last {
                                Text(String(filename))
                                    .font(.subheadline)
                                    .foregroundStyle(Color.duskTextSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(!usesDirectionalSelection)
                    .duskDirectionalFocusHighlight(focusedTarget == .version(version.id), shape: RoundedRectangle(cornerRadius: 12))
                    .listRowBackground(Color.duskSurface)
                    .id(FocusTarget.version(version.id))
                }
                .duskScrollContentBackgroundHidden()
                .background(Color.duskBackground)
                .onChange(of: focusedTarget) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func activate(_ target: FocusTarget) -> Bool {
        switch target {
        case .version(let id):
            return select(id)
        case .retry:
            Task { await viewModel.retry() }
            return true
        }
    }

    private func select(_ mediaID: Int) -> Bool {
        guard viewModel.versions.contains(where: { $0.id == mediaID }) else { return false }
        dismiss()
        Task {
            await playback.playVersion(
                ratingKey: request.ratingKey,
                mediaID: mediaID,
                resumeOffsetMilliseconds: request.resumeOffsetMilliseconds,
                placeholder: request.placeholder
            )
        }
        return true
    }
}

extension View {
    func duskMediaVersionPicker(request: Binding<MediaVersionPickerRequest?>) -> some View {
        modifier(MediaVersionPickerModifier(request: request))
    }
}

private struct MediaVersionPickerModifier: ViewModifier {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Binding var request: MediaVersionPickerRequest?

    func body(content: Content) -> some View {
        content.duskNavigationPanel(item: $request) { request in
            MediaVersionPickerView(request: request, plexService: plexService, downloadManager: downloadManager)
        }
    }
}

#if !os(tvOS)
import SwiftUI

/// The rows appended below the subtitle track list: a delay adjustment while a
/// sidecar subtitle is showing, and the entry point into subtitle search.
///
/// Returned as `PlayerSelectionExtraRow` models rather than views so the
/// selection lists can fold them into their directional focus scope — otherwise
/// keyboard and controller users can see these rows but never reach them.
@MainActor
enum PlayerSubtitleExtraRows {
    static func rows(
        controller: SidecarSubtitleController,
        onFindMore: @escaping () -> Void
    ) -> [PlayerSelectionExtraRow] {
        var rows: [PlayerSelectionExtraRow] = []

        if controller.isActive {
            rows.append(delayRow(controller: controller))
        }

        rows.append(
            PlayerSelectionExtraRow(
                id: "subtitles.findMore",
                title: "Find More…",
                subtitle: "Search your Plex server's subtitle providers",
                systemImage: "magnifyingglass",
                action: onFindMore
            )
        )

        return rows
    }

    /// Downloaded subtitles are often timed for a different release of the same
    /// title, which shows up as a constant offset. This corrects it live.
    private static func delayRow(
        controller: SidecarSubtitleController
    ) -> PlayerSelectionExtraRow {
        PlayerSelectionExtraRow(
            id: "subtitles.delay",
            title: "Subtitle Delay",
            subtitle: delayDescription(controller.delay),
            systemImage: "timer",
            adjuster: PlayerSelectionExtraRow.Adjuster(
                onDecrease: { controller.adjustDelay(by: -SidecarSubtitleController.delayStep) },
                onIncrease: { controller.adjustDelay(by: SidecarSubtitleController.delayStep) },
                onReset: { controller.setDelay(0) },
                canReset: controller.delay != 0
            ),
            // Return/controller A on a row whose Left/Right adjust the value
            // resets it, matching the visible reset button.
            action: { controller.setDelay(0) }
        )
    }

    private static func delayDescription(_ delay: TimeInterval) -> String {
        guard delay != 0 else { return "In sync" }
        let formatted = String(format: "%.1fs", abs(delay))
        return delay > 0 ? "\(formatted) later" : "\(formatted) earlier"
    }
}

/// Applies a subtitle the server just downloaded to the running session:
/// refreshes the cached metadata, re-derives the track list, and starts showing
/// the new sidecar — all without restarting playback.
@MainActor
func applyDownloadedSubtitle(
    _ outcome: PlayerSubtitleSearchViewModel.DownloadOutcome,
    viewModel: PlayerViewModel,
    playback: PlaybackCoordinator
) {
    // The coordinator rebuilds sessions (e.g. on a quality switch) from its
    // cached details, so the new stream has to land there too or the subtitle
    // silently disappears the next time playback restarts.
    playback.applyRefreshedItemDetails(outcome.details)
    viewModel.updateSourcePart(outcome.part)

    guard let streamID = outcome.newSubtitleStreamID else { return }
    let trackID = SubtitleTrack.externalTrackID(forPlexStreamID: streamID)
    guard let track = viewModel.subtitleTracks.first(where: { $0.id == trackID }) else { return }
    viewModel.selectSubtitle(track)
}
#endif

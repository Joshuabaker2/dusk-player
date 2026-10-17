import Foundation
import SwiftUI

/// Decides whether returning to the foreground should refresh the screens that
/// are already loaded.
///
/// Home, every visited library tab and every pushed detail page refresh on
/// `scenePhase == .active`. A brief trip away — Control Center, an app-switcher
/// peek, or on the Mac a covered, minimized or other-Space window, which cycles
/// the scene phase on ordinary app switching — would otherwise refresh all of
/// them at once (Home alone was ~90 Plex requests). Content is only refreshed
/// after the app has been away for at least `minimumAwayDuration`.
@MainActor
enum ForegroundRefresh {
    static let minimumAwayDuration: TimeInterval = 60

    private static var leftForegroundAt: Date?

    /// Called by the app scene for every phase change. Only the moment the app
    /// leaves `.active` is recorded, so screens can read it on their own
    /// `.active` change regardless of `onChange` ordering.
    static func scenePhaseDidChange(from oldPhase: ScenePhase, to newPhase: ScenePhase, now: Date = .now) {
        if oldPhase == .active, newPhase != .active {
            leftForegroundAt = now
        }
    }

    /// True when a screen seeing `.active` should refresh its content.
    static func shouldRefresh(now: Date = .now) -> Bool {
        guard let leftForegroundAt else { return false }
        return now.timeIntervalSince(leftForegroundAt) >= minimumAwayDuration
    }
}

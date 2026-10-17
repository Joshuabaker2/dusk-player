import SwiftUI
import UIKit

struct HomeItemContextMenu: View {
    let item: PlexItem
    let detailsLabel: String
    let onMarkWatched: () -> Void
    let onMarkUnwatched: () -> Void
    let onSelectRoute: (AppNavigationRoute) -> Void
    var onRemoveFromContinueWatching: (() -> Void)?

    var body: some View {
        if item.canMarkWatchedFromContextMenu {
            Button("Mark Watched", systemImage: "eye", action: onMarkWatched)
        }

        if item.canMarkUnwatchedFromContextMenu {
            Button("Mark Unwatched", systemImage: "eye.slash", action: onMarkUnwatched)
        }

        if let onRemoveFromContinueWatching {
            Button("Remove from Continue Watching", systemImage: "minus.circle", action: onRemoveFromContinueWatching)
        }

        Button(detailsLabel, systemImage: "info.circle") {
            onSelectRoute(AppNavigationRoute.destination(for: item))
        }

        if let seasonRoute = item.contextMenuSeasonRoute {
            Button("Go to Season", systemImage: "rectangle.stack") {
                onSelectRoute(seasonRoute)
            }
        }

        if let showRoute = item.contextMenuShowRoute {
            Button("Go to Show", systemImage: "tv.fill") {
                onSelectRoute(showRoute)
            }
        }
    }
}

struct HomeHeroActionButtonLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    #if os(tvOS)
    private let minimumButtonWidth: CGFloat = 340
    #endif

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(heroButtonFont)

            Text(title)
                .font(heroButtonFont)
                .lineLimit(1)
        }
        .frame(minHeight: heroButtonMinHeight)
        #if os(tvOS)
        .frame(minWidth: minimumButtonWidth)
        .contentShape(Capsule())
        #else
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .contentShape(Capsule())
        #endif
        .foregroundStyle(labelColor)
    }

    // iOS draws the home hero button as prominent, `Color.primary`-tinted glass,
    // so its label uses the inverse color for contrast. tvOS keeps translucent
    // glass where the standard `primary` label already reads correctly.
    private var labelColor: Color {
        #if os(tvOS)
        .primary
        #else
        .duskPrimaryActionLabel
        #endif
    }

    private var heroButtonFont: Font {
        #if os(tvOS)
        .subheadline.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }

    private var heroButtonMinHeight: CGFloat {
        #if os(tvOS)
        30
        #else
        32
        #endif
    }
}

struct HomeHeroSecondaryActionButtonLabel: View {
    let title: String

    #if os(tvOS)
    private let minimumButtonWidth: CGFloat = 340
    #endif

    var body: some View {
        Text(title)
            .font(heroButtonFont)
            #if os(tvOS)
            .frame(minWidth: minimumButtonWidth)
            .contentShape(Capsule())
            #endif
            .foregroundStyle(Color.primary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private var heroButtonFont: Font {
        #if os(tvOS)
        .subheadline.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        20
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        14
        #endif
    }
}

/// The active hero pill's rotation countdown.
struct HomeHeroPagerCountdown {
    /// Fraction of the rotation interval already elapsed.
    let progress: Double
    /// Seconds until the fill completes, or nil to hold at `progress` (paused).
    let remaining: TimeInterval?
    /// Changes whenever the countdown restarts, pauses, resumes or moves to
    /// another hero. `progress`/`remaining` are only read when it changes.
    let id: String
}

struct HomeHeroPagerPill: View {
    let isActive: Bool
    /// The active pill's countdown; nil draws the active pill full.
    var countdown: HomeHeroPagerCountdown? = nil

    var body: some View {
        let pillWidth: CGFloat = isActive ? 28 : 10
        let pillHeight: CGFloat = 10
        let fillInset: CGFloat = 1

        ZStack(alignment: .leading) {
            Capsule()
                .fill(isActive ? Color.primary.opacity(0.24) : Color.primary.opacity(0.28))

            if isActive {
                Group {
                    if let countdown {
                        HomeHeroPagerCountdownFill(countdown: countdown)
                    } else {
                        Capsule()
                            .fill(Color.primary)
                    }
                }
                .frame(
                    width: pillWidth - (fillInset * 2),
                    height: pillHeight - (fillInset * 2)
                )
                .padding(fillInset)
                .clipShape(Capsule())
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipShape(Capsule())
        .overlay {
            if isActive {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

/// Sweeps the active pill's fill with a Core Animation animation, so the
/// countdown costs no main-thread work while it runs. A 20 Hz `TimelineView`
/// here kept re-rendering the hero: ~8% CPU on an idle Home, including while the
/// window sat behind other apps on the Mac.
private struct HomeHeroPagerCountdownFill: UIViewRepresentable {
    let countdown: HomeHeroPagerCountdown

    func makeUIView(context: Context) -> HomeHeroPagerCountdownView {
        HomeHeroPagerCountdownView()
    }

    func updateUIView(_ view: HomeHeroPagerCountdownView, context: Context) {
        view.apply(countdown)
    }
}

private final class HomeHeroPagerCountdownView: UIView {
    private let fill = UIView()
    private var countdown: HomeHeroPagerCountdown?
    private var appliedAt: CFTimeInterval = 0
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        fill.backgroundColor = .label
        fill.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ newCountdown: HomeHeroPagerCountdown) {
        guard newCountdown.id != countdown?.id else { return }
        countdown = newCountdown
        appliedAt = CACurrentMediaTime()
        restartSweep()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The pill widens as it becomes active; resume the sweep at the new size.
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        restartSweep()
    }

    private func restartSweep() {
        let layer = fill.layer
        layer.removeAnimation(forKey: "sweep")
        guard let countdown, bounds.width > 0 else { return }

        let elapsed = CACurrentMediaTime() - appliedAt
        let startProgress = min(max(countdown.progress, 0), 1)
        let timeLeft = countdown.remaining.map { $0 - elapsed }
        let progress: Double
        if let remaining = countdown.remaining, remaining > 0 {
            progress = startProgress + (1 - startProgress) * min(max(elapsed / remaining, 0), 1)
        } else {
            progress = countdown.remaining == nil ? startProgress : 1
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = bounds.height / 2
        layer.position = CGPoint(x: 0, y: bounds.midY)
        layer.bounds = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)

        if let timeLeft, timeLeft > 0, progress < 1 {
            let sweep = CABasicAnimation(keyPath: "bounds.size.width")
            sweep.fromValue = bounds.width * progress
            sweep.toValue = bounds.width
            sweep.duration = timeLeft
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.bounds.size.width = bounds.width
            layer.add(sweep, forKey: "sweep")
        }
        CATransaction.commit()
    }
}

extension View {
    @ViewBuilder
    func homeHeroNativeButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(Color.primary)
        #elseif os(iOS)
        // Prominent glass tinted with a translucent `primary` so the hero CTA
        // contrasts the artwork (dark in Light mode, light in Dark) while still
        // reading as liquid glass. `.regular` height keeps it a short, wide pill.
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.duskPrimaryButtonTint)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #else
        self
        #endif
    }
}

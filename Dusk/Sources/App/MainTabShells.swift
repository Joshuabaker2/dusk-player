import SwiftUI
import UIKit

enum MainTabItem: Hashable, Identifiable {
    case home
    case library(PlexLibraryType)
    case liveTV
    case downloads
    case search
    case settings
    case more

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library(let libraryType):
            libraryType.tabTitle
        case .liveTV:
            "Live TV"
        case .downloads:
            "Downloads"
        case .search:
            "Search"
        case .settings:
            "Settings"
        case .more:
            "More"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .library(let libraryType):
            libraryType.systemImage
        case .liveTV:
            "dot.radiowaves.left.and.right"
        case .downloads:
            "arrow.down.circle"
        case .search:
            "magnifyingglass"
        case .settings:
            "gearshape"
        case .more:
            "ellipsis"
        }
    }
}

struct MainTabIOSShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab
                ) {
                    content(tab)
                        .tint(Color.duskAccent)
                }
            }
        }
        .tint(.primary)
    }
}

struct MainTabTVShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                content(tab)
                    .background {
                        DuskTVTabBarTintPin()
                            .frame(width: 0, height: 0)
                    }
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                            .symbolRenderingMode(.monochrome)
                    }
            }
        }
        .tint(Color.duskTVTabBarTint)
        .background(Color.duskBackground.ignoresSafeArea())
    }
}

/// Zero-size helper that keeps the tvOS tab bar tinted with
/// `Color.duskTVTabBarTint`.
///
/// The app's global accent color (Sunset Coral) is the window tint, so every
/// UIKit view that inherits its tint gets coral. SwiftUI's `.tint` on the tvOS
/// `TabView` is not sticky: returning from a pushed detail screen or from the
/// full-screen player can leave the real `UITabBar` back on the inherited
/// window tint, which paints the selected tab item coral instead of the dark
/// chrome color. Pinning the bar's own `tintColor` makes it explicit, so it no
/// longer inherits, and re-pinning on every shell update repairs it if SwiftUI
/// overwrites it again. A zero-size sentinel view inside the bar catches every
/// later tint change UIKit reports and re-pins, so the repair does not depend
/// on SwiftUI scheduling another shell update. The tvOS window tint itself is
/// the same dark color (`AccentColorTV` in the asset catalog), so even a bar
/// that does inherit no longer has coral to inherit.
private struct DuskTVTabBarTintPin: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DuskTVTabBarTintController {
        DuskTVTabBarTintController()
    }

    func updateUIViewController(_ uiViewController: DuskTVTabBarTintController, context: Context) {
        uiViewController.pinTabBarTint()
    }
}

private final class DuskTVTabBarTintController: UIViewController {
    private var hasPendingPin = false

    private lazy var sentinel: DuskTVTabBarTintSentinel = {
        let sentinel = DuskTVTabBarTintSentinel(frame: .zero)
        sentinel.isUserInteractionEnabled = false
        sentinel.backgroundColor = .clear
        sentinel.onTintColorChange = { [weak self] in
            self?.scheduleTabBarTintRepair()
        }
        return sentinel
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pinTabBarTint()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pinTabBarTint()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        pinTabBarTint()
    }

    func pinTabBarTint() {
        applyTabBarTint()

        // A navigation pop or player dismissal can re-tint the bar later in the
        // same update pass, so take a second look once the run loop settles.
        scheduleTabBarTintRepair()
    }

    /// Re-applies the tint on the next run loop turn. Used both after a shell
    /// update and when the sentinel reports that the bar's tint changed, which
    /// keeps the repair out of UIKit's own tint-change notification pass.
    private func scheduleTabBarTintRepair() {
        guard !hasPendingPin else { return }
        hasPendingPin = true
        DispatchQueue.main.async { [weak self] in
            self?.hasPendingPin = false
            self?.applyTabBarTint()
        }
    }

    private func applyTabBarTint() {
        guard let tabBar = resolvedTabBar() else { return }
        installSentinel(in: tabBar)
        guard tabBar.tintColor != UIColor.duskTVTabBarTint else { return }
        tabBar.tintColor = .duskTVTabBarTint
    }

    private func installSentinel(in tabBar: UITabBar) {
        guard sentinel.superview !== tabBar else { return }
        sentinel.removeFromSuperview()
        tabBar.addSubview(sentinel)
    }

    private func resolvedTabBar() -> UITabBar? {
        if let tabBar = tabBarController?.tabBar {
            return tabBar
        }
        // The shell is always hosted in a tab bar controller today; the view
        // search only covers a host that keeps the bar outside the parent chain.
        guard let window = view.window else { return nil }
        return Self.firstTabBar(in: window)
    }

    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar {
            return tabBar
        }

        for subview in view.subviews {
            if let tabBar = firstTabBar(in: subview) {
                return tabBar
            }
        }

        return nil
    }
}

/// Invisible subview of the tab bar. UIKit calls `tintColorDidChange()` on
/// every subview whenever the bar's effective tint changes, explicit or
/// inherited, which is the one hook that fires no matter who re-tinted the bar.
private final class DuskTVTabBarTintSentinel: UIView {
    var onTintColorChange: (() -> Void)?

    override func tintColorDidChange() {
        super.tintColorDidChange()
        onTintColorChange?()
    }
}

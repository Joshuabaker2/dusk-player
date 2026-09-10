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
/// overwrites it again.
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
        guard !hasPendingPin else { return }
        hasPendingPin = true
        DispatchQueue.main.async { [weak self] in
            self?.hasPendingPin = false
            self?.applyTabBarTint()
        }
    }

    private func applyTabBarTint() {
        guard let tabBar = resolvedTabBar() else { return }
        guard tabBar.tintColor != UIColor.duskTVTabBarTint else { return }
        tabBar.tintColor = .duskTVTabBarTint
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

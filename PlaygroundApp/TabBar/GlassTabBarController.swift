import SwiftUI
import UIKit

/// Native liquid-glass tab bar with one "prominent" item (Test) whose icon, caption, and black
/// pill background are all baked into a single flattened image and assigned through the public
/// `UITabBarItem.image` API — no private view hierarchy involved.
final class GlassTabBarController: UITabBarController {

    private enum Tab: Int, CaseIterable {
        case alerts, chart, test, shop, profile

        var title: String {
            switch self {
            case .alerts: "Alerts"
            case .chart: "Chart"
            case .test: "Test"
            case .shop: "Shop"
            case .profile: "Profile"
            }
        }

        var symbol: String {
            switch self {
            case .alerts: "bell.badge"
            case .chart: "chart.xyaxis.line"
            case .test: "checkmark.seal"
            case .shop: "bag"
            case .profile: "person"
            }
        }
    }

    /// Badge states the prominent tab cycles through on each tap, so both the post-action
    /// colour change and the native empty-badge dot can be seen without a rebuild.
    private enum BadgeState: CaseIterable {
        case unread, acted, empty

        /// `nil` hides the badge entirely; an empty string is what makes UIKit draw a plain dot
        /// instead of a numbered/text badge — this is native `UITabBarItem` behaviour, not
        /// something drawn by hand.
        var value: String? {
            switch self {
            case .unread, .acted: "P"
            case .empty: ""
            }
        }

        var color: UIColor {
            switch self {
            case .unread: UIColor(red: 0.85, green: 0.25, blue: 0.16, alpha: 1)
            case .acted, .empty: .systemGray
            }
        }
    }

    private let prominentTab = Tab.test
    private var badgeState = BadgeState.unread

    /// The prominent tab's own `UITabBarItem`, kept so the badge can be updated on tap without
    /// re-walking the view hierarchy to find it.
    private var prominentItem: UITabBarItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        viewControllers = Tab.allCases.map { tab in
            let controller = makeViewController(for: tab)
            let item = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), tag: tab.rawValue)
            if tab == prominentTab {
                let pillImage = ProminentTabIconRenderer.makeImage(symbol: tab.symbol, title: tab.title)
                    .withRenderingMode(.alwaysOriginal)
                item.image = pillImage
                item.selectedImage = pillImage
                item.title = nil
                prominentItem = item
            }
            controller.tabBarItem = item

            // AlertsView brings its own SwiftUI NavigationStack, so wrapping it in a
            // UINavigationController too would show two stacked nav bars.
            guard tab != .alerts else { return controller }
            return UINavigationController(rootViewController: controller)
        }

        applyBadgeState()
    }

    private func makeViewController(for tab: Tab) -> UIViewController {
        switch tab {
        case .alerts:
            UIHostingController(rootView: AlertsView())
        case .chart, .test, .shop, .profile:
            PlaceholderViewController(title: tab.title)
        }
    }

    override func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard item.tag == prominentTab.rawValue else { return }
        advanceBadgeState()
    }

    private func advanceBadgeState() {
        let states = BadgeState.allCases
        guard let index = states.firstIndex(of: badgeState) else { return }
        badgeState = states[(index + 1) % states.count]
        applyBadgeState()
    }

    private func applyBadgeState() {
        prominentItem?.badgeValue = badgeState.value
        prominentItem?.badgeColor = badgeState.color
    }
}

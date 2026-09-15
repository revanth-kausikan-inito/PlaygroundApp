import SwiftUI
import UIKit

/// Native liquid-glass tab bar with one "prominent" item (Test) drawn as a filled black pill,
/// matching the Figma home design.
///
/// UIKit exposes no per-item background. Injecting one into the private `_UITabButton` does not
/// work either: the floating platter composites its content through the glass material as a
/// luminance mask, so white icons and labels are knocked out entirely. Instead the item's real
/// content is hidden and an opaque replacement — capsule, icon, title, badge — is layered on top
/// of the tab bar, outside the masked content. Touch handling is untouched: the overlay is
/// non-interactive and the real button still receives the tap.
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
    /// colour change and the collapsed empty-badge size can be seen without a rebuild.
    private enum BadgeState: CaseIterable {
        case unread, acted, empty

        var text: String? {
            switch self {
            case .unread, .acted: "P"
            case .empty: nil
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

    private let pillOverlay = ProminentTabPillView()

    override func viewDidLoad() {
        super.viewDidLoad()

        viewControllers = Tab.allCases.map { tab in
            let controller = makeViewController(for: tab)
            controller.tabBarItem = UITabBarItem(
                title: tab.title,
                image: UIImage(systemName: tab.symbol),
                tag: tab.rawValue
            )
            // AlertsView brings its own SwiftUI NavigationStack, so wrapping it in a
            // UINavigationController too would show two stacked nav bars.
            guard tab != .alerts else { return controller }
            return UINavigationController(rootViewController: controller)
        }

        pillOverlay.configure(symbol: prominentTab.symbol, title: prominentTab.title)
        applyBadgeState()
        tabBar.addSubview(pillOverlay)
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
        pillOverlay.badgeText = badgeState.text
        pillOverlay.badgeColor = badgeState.color
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPillOverlay()
    }

    private func layoutPillOverlay() {
        let buttons = prominentButtons()
        guard let reference = buttons.first else {
            pillOverlay.isHidden = true
            return
        }
        pillOverlay.isHidden = false

        // The real content would otherwise show through as a dark silhouette behind the pill.
        buttons.forEach(hideContent(of:))

        pillOverlay.frame = reference.convert(reference.bounds, to: tabBar).insetBy(dx: 3, dy: 0)
        tabBar.bringSubviewToFront(pillOverlay)
    }

    private func hideContent(of button: UIView) {
        for view in button.subviews where view is UIImageView || NSStringFromClass(type(of: view)).contains("TitleWrapperView") {
            view.alpha = 0
        }
    }

    /// Every `_UITabButton` for the prominent item — UIKit builds one per container it renders
    /// the bar's content in (the plain platter, and the liquid lens' selected-content copy).
    private func prominentButtons() -> [UIView] {
        var buttons: [UIView] = []
        func walk(_ view: UIView) {
            if NSStringFromClass(type(of: view)) == "_UITabButton" { buttons.append(view) }
            view.subviews.forEach(walk)
        }
        walk(tabBar)

        return Dictionary(grouping: buttons, by: { ObjectIdentifier($0.superview ?? tabBar) })
            .values
            .compactMap { group -> UIView? in
                guard group.count == Tab.allCases.count else { return nil }
                return group.sorted { $0.frame.minX < $1.frame.minX }[prominentTab.rawValue]
            }
    }
}

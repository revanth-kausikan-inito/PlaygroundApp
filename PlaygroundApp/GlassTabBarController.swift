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
        case home, chart, test, shop, profile

        var title: String {
            switch self {
            case .home: "Home"
            case .chart: "Chart"
            case .test: "Test"
            case .shop: "Shop"
            case .profile: "Profile"
            }
        }

        var symbol: String {
            switch self {
            case .home: "drop.fill"
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
            let controller = PlaceholderViewController(title: tab.title)
            controller.tabBarItem = UITabBarItem(
                title: tab.title,
                image: UIImage(systemName: tab.symbol),
                tag: tab.rawValue
            )
            return UINavigationController(rootViewController: controller)
        }

        pillOverlay.configure(symbol: prominentTab.symbol, title: prominentTab.title)
        applyBadgeState()
        tabBar.addSubview(pillOverlay)
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

/// Opaque stand-in for the prominent tab item: black capsule, white icon and title, red badge.
private final class ProminentTabPillView: UIView {

    /// Badge text; an empty or nil value collapses the badge to a bare dot.
    var badgeText: String? {
        didSet {
            badgeLabel.text = badgeText
            setNeedsLayout()
        }
    }

    var badgeColor: UIColor = .systemRed {
        didSet { badgeLabel.backgroundColor = badgeColor }
    }

    private var hasBadgeText: Bool { !(badgeText ?? "").isEmpty }

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        backgroundColor = .black

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.backgroundColor = badgeColor
        badgeLabel.layer.masksToBounds = true

        [iconView, titleLabel, badgeLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(symbol: String, title: String) {
        iconView.image = UIImage(systemName: symbol)?.withRenderingMode(.alwaysTemplate)
        titleLabel.text = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2

        let iconSize: CGFloat = 26
        iconView.frame = CGRect(
            x: bounds.midX - iconSize / 2,
            y: bounds.minY + 6,
            width: iconSize,
            height: iconSize
        )
        titleLabel.frame = CGRect(x: 0, y: iconView.frame.maxY + 2, width: bounds.width, height: 13)

        // The badge straddles the capsule's top-right edge, as in the design. An empty badge
        // shrinks to a dot around that same anchor point, so the size change is visible in place.
        let badgeSize: CGFloat = hasBadgeText ? 20 : 10
        let anchor = CGPoint(x: bounds.maxX - 5, y: bounds.minY + 9)
        badgeLabel.frame = CGRect(
            x: anchor.x - badgeSize / 2,
            y: anchor.y - badgeSize / 2,
            width: badgeSize,
            height: badgeSize
        )
        badgeLabel.layer.cornerRadius = badgeSize / 2
    }
}

private final class PlaceholderViewController: UIViewController {
    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        // Colourful content that scrolls under the bar, so the glass effect is visible.
        for index in 0..<30 {
            let row = UILabel()
            row.text = "\(title ?? "") row \(index)"
            row.font = .systemFont(ofSize: 20, weight: .medium)
            row.backgroundColor = UIColor(hue: CGFloat(index) / 30, saturation: 0.35, brightness: 0.95, alpha: 1)
            row.textAlignment = .center
            row.heightAnchor.constraint(equalToConstant: 60).isActive = true
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }
}

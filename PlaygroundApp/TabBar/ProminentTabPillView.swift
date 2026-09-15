import UIKit

/// Opaque stand-in for the prominent tab item: black capsule, white icon and title, red badge.
final class ProminentTabPillView: UIView {

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

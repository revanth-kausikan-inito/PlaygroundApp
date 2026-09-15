import UIKit

/// Draws the "Test" tab's pill background, icon, and caption together as one flat image, so it
/// can be assigned directly through the public `UITabBarItem.image` API instead of hooking into
/// the tab bar's private view hierarchy the way the earlier overlay-based approach did.
///
/// The image must be assigned with rendering mode `.alwaysOriginal` — the default template mode
/// would flatten every non-transparent pixel to a single tint colour, destroying the black
/// background / white content contrast baked in here.
enum ProminentTabIconRenderer {
    /// Close to the footprint UIKit already gives a standard tab icon, so there's little room
    /// for it to rescale this image down and blur the baked-in text.
    static let imageSize = CGSize(width: 60, height: 40)

    static func makeImage(symbol: String, title: String) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { _ in
            let pillRect = CGRect(origin: .zero, size: imageSize)
            UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).addClip()
            UIColor.black.setFill()
            UIRectFill(pillRect)

            let iconConfig = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            if let icon = UIImage(systemName: symbol, withConfiguration: iconConfig)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                icon.draw(at: CGPoint(x: (imageSize.width - icon.size.width) / 2, y: 5))
            }

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let titleSize = title.size(withAttributes: titleAttributes)
            let titleOrigin = CGPoint(
                x: (imageSize.width - titleSize.width) / 2,
                y: imageSize.height - titleSize.height - 4
            )
            title.draw(at: titleOrigin, withAttributes: titleAttributes)
        }
    }
}

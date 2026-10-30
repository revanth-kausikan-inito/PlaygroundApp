import ImageIO
import UIKit

/// Downsamples capture JPEGs for the gallery grid. Decoding full 1080×1920 frames into a
/// scrolling grid is what makes it stutter, so ImageIO is asked for a thumbnail instead of
/// the whole image.
nonisolated enum QRThumbnailLoader {

    // NSCache is thread-safe, so it needs no lock of its own.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func thumbnail(for url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.lastPathComponent)@\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    static func fullImage(for url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

import AppKit
import Foundation

final class ImageCache {
    private final class WrappedImage {
        let image: NSImage

        init(image: NSImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSURL, WrappedImage>()

    init(countLimit: Int = 60) {
        cache.countLimit = countLimit
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    func setImage(_ image: NSImage, for url: URL) {
        cache.setObject(WrappedImage(image: image), forKey: url as NSURL)
    }

    func clear() {
        cache.removeAllObjects()
    }
}

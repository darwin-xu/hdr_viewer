import AppKit
import Foundation
import ImageIO

@MainActor
final class ThumbnailProvider: ObservableObject {
    @Published private(set) var thumbnails: [URL: NSImage] = [:]

    private let cache = NSCache<NSURL, NSImage>()

    init(countLimit: Int = 400) {
        cache.countLimit = countLimit
    }

    func requestThumbnail(for url: URL, maxPixelSize: Int = 320) {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            thumbnails[url] = cached
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard
                let self,
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            await MainActor.run {
                self.cache.setObject(image, forKey: key)
                self.thumbnails[url] = image
            }
        }
    }
}

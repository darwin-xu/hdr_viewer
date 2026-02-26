import AppKit
import AVFoundation
import Foundation
import ImageIO

@MainActor
final class ThumbnailProvider: ObservableObject {
    @Published private(set) var thumbnails: [URL: NSImage] = [:]

    private let cache = NSCache<NSURL, NSImage>()
    private let decodeService = ImageDecodeService()
    private static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf"]

    init(countLimit: Int = 400) {
        cache.countLimit = countLimit
    }

    func requestThumbnail(for url: URL, maxPixelSize: Int = 320) {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            thumbnails[url] = cached
            return
        }

        let decodeService = self.decodeService
        let isVideo = PhotoItem.videoExtensions.contains(url.pathExtension.lowercased())

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let fileName = url.lastPathComponent
            let image: NSImage?

            if isVideo {
                image = self.thumbnailViaAVAsset(url: url, maxPixelSize: maxPixelSize)
            } else {
                // Try CGImageSource thumbnail first (fast path)
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]

                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    Logger.shared.debug("Thumbnail via CGImageSource: \(fileName) \(cgImage.width)x\(cgImage.height)", source: "Thumbnail")
                    image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                } else {
                    Logger.shared.warning("CGImageSource thumbnail failed for \(fileName), trying decode fallback", source: "Thumbnail")
                    image = self.thumbnailViaDecodeService(url: url, maxPixelSize: maxPixelSize, decodeService: decodeService)
                }
            } else {
                Logger.shared.warning("CGImageSource creation failed for \(fileName), trying decode fallback", source: "Thumbnail")
                image = self.thumbnailViaDecodeService(url: url, maxPixelSize: maxPixelSize, decodeService: decodeService)
                }
            } // end image path

            guard let image else {
                Logger.shared.error("All thumbnail methods failed for \(fileName)", source: "Thumbnail")
                return
            }

            await MainActor.run {
                self.cache.setObject(image, forKey: key)
                self.thumbnails[url] = image
            }
        }
    }

    /// Fallback: use ImageDecodeService (which can extract embedded JPEGs from RAW)
    /// and scale the result down for thumbnail use.
    private nonisolated func thumbnailViaDecodeService(
        url: URL,
        maxPixelSize: Int,
        decodeService: ImageDecodeService
    ) -> NSImage? {
        do {
            let fullImage = try decodeService.decodeImage(from: url, maxPixelSize: maxPixelSize)
            let scaled = scaledThumbnail(from: fullImage, maxPixelSize: maxPixelSize)
            Logger.shared.debug("Thumbnail via decode fallback: \(url.lastPathComponent) \(Int(scaled.size.width))x\(Int(scaled.size.height))", source: "Thumbnail")
            return scaled
        } catch {
            Logger.shared.error("Decode fallback thumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)", source: "Thumbnail")
            return nil
        }
    }

    /// Scale an NSImage down to fit within maxPixelSize, preserving aspect ratio.
    private nonisolated func scaledThumbnail(from image: NSImage, maxPixelSize: Int) -> NSImage {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return image }

        let maxDim = CGFloat(maxPixelSize)
        if w <= maxDim && h <= maxDim { return image }

        let scale = min(maxDim / w, maxDim / h)
        let newW = w * scale
        let newH = h * scale

        let newImage = NSImage(size: NSSize(width: newW, height: newH))
        newImage.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: newW, height: newH),
            from: NSRect(x: 0, y: 0, width: w, height: h),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    /// Generate first-frame thumbnail from a video asset.
    private nonisolated func thumbnailViaAVAsset(url: URL, maxPixelSize: Int) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            Logger.shared.debug("Thumbnail via AVAsset: \(url.lastPathComponent) \(cgImage.width)x\(cgImage.height)", source: "Thumbnail")
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            Logger.shared.error("AVAsset thumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)", source: "Thumbnail")
            return nil
        }
    }
}

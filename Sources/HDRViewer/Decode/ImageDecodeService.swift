import AppKit
import CoreImage
import ImageIO

enum ImageDecodeError: Error, LocalizedError {
    case failedToCreateImageSource
    case failedToDecodeImage

    var errorDescription: String? {
        switch self {
        case .failedToCreateImageSource:
            return "Unable to create image source."
        case .failedToDecodeImage:
            return "Unable to decode image."
        }
    }
}

final class ImageDecodeService {
    private let ciContext = CIContext(options: nil)
    private static let rawPreviewMaxPixelSize = 4096

    func decodeImage(from url: URL, maxPixelSize: Int? = nil) throws -> NSImage {
        if maxPixelSize == nil {
            do {
                let ciImage = try decodeCIImage(from: url)
                return try makeNSImage(from: ciImage)
            } catch {
                if let embeddedJPEG = extractLargestEmbeddedJPEG(from: url) {
                    return embeddedJPEG
                }
                throw error
            }
        }

        let ext = url.pathExtension.lowercased()
        if isRAW(ext: ext) {
            do {
                return try decodeRAW(from: url)
            } catch {
                if let embeddedJPEG = extractLargestEmbeddedJPEG(from: url) {
                    return embeddedJPEG
                }
                throw error
            }
        }
        return try decodeRaster(from: url, maxPixelSize: maxPixelSize)
    }

    func decodeCIImage(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if isRAW(ext: ext) {
            return try decodeRAWCIImage(from: url)
        }

        let hdrOptions: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .expandToHDR: true
        ]

        if let image = CIImage(contentsOf: url, options: hdrOptions) {
            return image
        }

        if let fallbackImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            return fallbackImage
        }

        throw ImageDecodeError.failedToDecodeImage
    }

    private func decodeRaster(from url: URL, maxPixelSize: Int?) throws -> NSImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageDecodeError.failedToCreateImageSource
        }

        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ]

        if let maxPixelSize {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ImageDecodeError.failedToDecodeImage
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func decodeRAW(from url: URL) throws -> NSImage {
        let outputImage = try decodeCIImage(from: url)
        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw ImageDecodeError.failedToDecodeImage
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func makeNSImage(from ciImage: CIImage) throws -> NSImage {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ImageDecodeError.failedToDecodeImage
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func decodeRAWCIImage(from url: URL) throws -> CIImage {
        if
            let rawFilter = CIFilter(imageURL: url)
        {
            rawFilter.setDefaults()
            if let outputImage = rawFilter.outputImage {
                return outputImage
            }
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageDecodeError.failedToCreateImageSource
        }

        let fullImageOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ]

        if let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, fullImageOptions as CFDictionary) {
            return CIImage(cgImage: cgImage)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.rawPreviewMaxPixelSize
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) {
            return CIImage(cgImage: cgImage)
        }

        // Last resort: extract embedded JPEG from the RAW container
        if let embeddedJPEG = extractLargestEmbeddedJPEG(from: url),
           let tiffData = embeddedJPEG.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let cgImage = bitmap.cgImage
        {
            return CIImage(cgImage: cgImage)
        }

        throw ImageDecodeError.failedToDecodeImage
    }

    // MARK: - Embedded JPEG extraction

    /// Scans the raw file bytes for embedded JPEG segments (SOI FF D8 … EOI FF D9)
    /// and returns the largest one that decodes successfully.
    /// Nikon NEF (including High Efficiency) embeds a full-resolution JPEG preview
    /// alongside the actual sensor data. When the RAW codec is unavailable on the
    /// host macOS version this preview is the best image we can display.
    private func extractLargestEmbeddedJPEG(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }

        let bytes = data.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }
        let count = data.count
        var bestImage: NSImage?
        var bestPixelCount = 0
        var pos = 0

        while pos < count - 1 {
            // Find JPEG SOI marker (FF D8)
            guard bytes[pos] == 0xFF, bytes[pos + 1] == 0xD8 else {
                pos += 1
                continue
            }

            let soiPos = pos
            var j = soiPos + 2

            // Find matching EOI marker (FF D9)
            while j < count - 1 {
                if bytes[j] == 0xFF && bytes[j + 1] == 0xD9 {
                    break
                }
                j += 1
            }

            guard j < count - 1 else { break }
            let eoiEnd = j + 2
            let segmentLength = eoiEnd - soiPos

            // Skip tiny segments (< 50 KB) – they're thumbnails or metadata
            if segmentLength > 50_000 {
                let jpegData = data[soiPos..<eoiEnd]
                if let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                   let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                {
                    let px = cgImage.width * cgImage.height
                    if px > bestPixelCount {
                        bestPixelCount = px
                        bestImage = NSImage(
                            cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height)
                        )
                    }
                }
            }

            pos = eoiEnd
        }

        return bestImage
    }

    private func isRAW(ext: String) -> Bool {
        ["dng", "cr2", "cr3", "nef", "arw", "raf"].contains(ext)
    }
}

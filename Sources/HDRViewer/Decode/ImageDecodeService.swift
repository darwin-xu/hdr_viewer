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

    func decodeImage(from url: URL, maxPixelSize: Int? = nil) throws -> NSImage {
        if maxPixelSize == nil {
            let ciImage = try decodeCIImage(from: url)
            return try makeNSImage(from: ciImage)
        }

        let ext = url.pathExtension.lowercased()
        if isRAW(ext: ext) {
            return try decodeRAW(from: url)
        }
        return try decodeRaster(from: url, maxPixelSize: maxPixelSize)
    }

    func decodeCIImage(from url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        if isRAW(ext: ext) {
            guard let rawFilter = CIFilter(imageURL: url) else {
                throw ImageDecodeError.failedToDecodeImage
            }

            rawFilter.setDefaults()

            guard let outputImage = rawFilter.outputImage else {
                throw ImageDecodeError.failedToDecodeImage
            }

            return outputImage
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

    private func isRAW(ext: String) -> Bool {
        ["dng", "cr2", "cr3", "nef", "arw", "raf"].contains(ext)
    }
}

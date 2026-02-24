import Foundation
import ImageIO

struct PhotoMetadata {
    let width: Int?
    let height: Int?
    let cameraModel: String?
    let lensModel: String?
    let iso: Int?
    let exposureTime: String?
    let fNumber: Double?
    let focalLength: Double?
}

final class MetadataService {
    func readMetadata(from url: URL) -> PhotoMetadata {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return PhotoMetadata(
                width: nil,
                height: nil,
                cameraModel: nil,
                lensModel: nil,
                iso: nil,
                exposureTime: nil,
                fNumber: nil,
                focalLength: nil
            )
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        return PhotoMetadata(
            width: properties[kCGImagePropertyPixelWidth] as? Int,
            height: properties[kCGImagePropertyPixelHeight] as? Int,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            exposureTime: formatExposure(exif?[kCGImagePropertyExifExposureTime]),
            fNumber: exif?[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif?[kCGImagePropertyExifFocalLength] as? Double
        )
    }

    private func formatExposure(_ value: Any?) -> String? {
        guard let exposure = value as? Double, exposure > 0 else { return nil }
        if exposure >= 1 { return String(format: "%.2fs", exposure) }
        let inverse = Int((1.0 / exposure).rounded())
        return "1/\(inverse)s"
    }
}

import AVFoundation
import CoreMedia
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

    // Video-specific fields (nil for images)
    let duration: Double?
    let videoCodec: String?
    let audioCodec: String?
    let frameRate: Double?
    let videoBitRate: Double?
    let isHDRVideo: Bool
}

extension PhotoMetadata {
    /// Convenience initializer for image metadata (video fields default to nil/false).
    static func image(
        width: Int?, height: Int?, cameraModel: String?, lensModel: String?,
        iso: Int?, exposureTime: String?, fNumber: Double?, focalLength: Double?
    ) -> PhotoMetadata {
        PhotoMetadata(
            width: width, height: height, cameraModel: cameraModel, lensModel: lensModel,
            iso: iso, exposureTime: exposureTime, fNumber: fNumber, focalLength: focalLength,
            duration: nil, videoCodec: nil, audioCodec: nil, frameRate: nil,
            videoBitRate: nil, isHDRVideo: false
        )
    }
}

final class MetadataService: @unchecked Sendable {
    func readMetadata(from url: URL) -> PhotoMetadata {
        let ext = url.pathExtension.lowercased()
        if PhotoItem.videoExtensions.contains(ext) {
            return readVideoMetadata(from: url)
        }
        return readImageMetadata(from: url)
    }

    // MARK: - Image metadata

    private func readImageMetadata(from url: URL) -> PhotoMetadata {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return .image(width: nil, height: nil, cameraModel: nil, lensModel: nil,
                          iso: nil, exposureTime: nil, fNumber: nil, focalLength: nil)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        return .image(
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

    // MARK: - Video metadata

    private func readVideoMetadata(from url: URL) -> PhotoMetadata {
        let asset = AVAsset(url: url)
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)

        let videoTrack = videoTracks.first
        let size = videoTrack?.naturalSize ?? .zero
        let transform = videoTrack?.preferredTransform ?? .identity
        let transformedSize = size.applying(transform)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        let duration = CMTimeGetSeconds(asset.duration)
        let frameRate: Double? = videoTrack.map { Double($0.nominalFrameRate) }
        let videoBitRate: Double? = videoTrack.map { Double($0.estimatedDataRate) }

        let videoCodec = videoTrack.flatMap { track -> String? in
            for desc in track.formatDescriptions {
                let formatDesc = desc as! CMFormatDescription
                let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
                return fourCCToString(codecType)
            }
            return nil
        }

        let audioCodec = audioTracks.first.flatMap { track -> String? in
            for desc in track.formatDescriptions {
                let formatDesc = desc as! CMFormatDescription
                let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
                return fourCCToString(codecType)
            }
            return nil
        }

        let isHDR = detectVideoHDR(tracks: videoTracks)

        return PhotoMetadata(
            width: width > 0 ? width : nil,
            height: height > 0 ? height : nil,
            cameraModel: nil, lensModel: nil, iso: nil,
            exposureTime: nil, fNumber: nil, focalLength: nil,
            duration: duration.isFinite && duration > 0 ? duration : nil,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            frameRate: frameRate,
            videoBitRate: videoBitRate,
            isHDRVideo: isHDR
        )
    }

    /// Detect HDR by checking video track format descriptions for HLG, PQ (HDR10),
    /// or Dolby Vision transfer functions / extensions.
    private func detectVideoHDR(tracks: [AVAssetTrack]) -> Bool {
        let log = Logger.shared
        let hdrTransferFunctions: Set<String> = [
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        ]
        let tfKey = kCMFormatDescriptionExtension_TransferFunction as String

        for track in tracks {
            for desc in track.formatDescriptions {
                let formatDesc = desc as! CMFormatDescription
                guard let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] else {
                    log.debug("detectVideoHDR: no extensions on format description", source: "Metadata")
                    continue
                }

                log.debug("detectVideoHDR: extension keys = \(Array(extensions.keys))", source: "Metadata")

                // Check transfer function (HLG / PQ)
                if let tf = extensions[tfKey] as? String {
                    log.debug("detectVideoHDR: TransferFunction = \(tf)", source: "Metadata")
                    if hdrTransferFunctions.contains(tf) {
                        log.info("detectVideoHDR: HDR detected via transfer function \(tf)", source: "Metadata")
                        return true
                    }
                }

                // Check for Dolby Vision configuration records
                if extensions["DolbyVisionConfigurationRecord"] != nil {
                    log.info("detectVideoHDR: HDR detected via DolbyVisionConfigurationRecord", source: "Metadata")
                    return true
                }
                if extensions["DolbyVisionELConfigurationRecord"] != nil {
                    log.info("detectVideoHDR: HDR detected via DolbyVisionELConfigurationRecord", source: "Metadata")
                    return true
                }

                // Check color primaries as supplementary indicator (BT.2020)
                let cpKey = kCMFormatDescriptionExtension_ColorPrimaries as String
                if let cp = extensions[cpKey] as? String {
                    log.debug("detectVideoHDR: ColorPrimaries = \(cp)", source: "Metadata")
                    let bt2020 = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
                    if cp == bt2020 {
                        log.info("detectVideoHDR: HDR detected via BT.2020 color primaries", source: "Metadata")
                        return true
                    }
                }
            }
        }
        log.debug("detectVideoHDR: no HDR indicators found (\(tracks.count) tracks)", source: "Metadata")
        return false
    }

    private func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    private func formatExposure(_ value: Any?) -> String? {
        guard let exposure = value as? Double, exposure > 0 else { return nil }
        if exposure >= 1 { return String(format: "%.2fs", exposure) }
        let inverse = Int((1.0 / exposure).rounded())
        return "1/\(inverse)s"
    }
}

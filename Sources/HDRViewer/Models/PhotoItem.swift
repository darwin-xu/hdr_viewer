import Foundation

enum MediaKind {
    case image
    case video
}

enum PhotoSourceType {
    case nativeHDR
    case sdr
    case raw
    case video      // non-HDR video
    case videoHDR   // HDR video (HLG / Dolby Vision / PQ)
}

enum HDRBoostMode {
    case none
    case sdr
    case raw
    case video
}

struct PhotoItem: Identifiable, Hashable {
    let id: URL
    let url: URL

    var fileName: String {
        url.lastPathComponent
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heif", "heic",
        "dng", "cr2", "cr3", "nef", "arw", "raf"
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "mts", "m2ts"
    ]

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "dng"
    ]

    var mediaKind: MediaKind {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { return .video }
        return .image
    }

    var isVideo: Bool { mediaKind == .video }

    var sourceType: PhotoSourceType {
        let ext = url.pathExtension.lowercased()

        if Self.videoExtensions.contains(ext) {
            // Actual HDR detection happens at decode time via AVAsset track info;
            // default to .video here, ViewModel will upgrade to .videoHDR if detected.
            return .video
        }

        if Self.rawExtensions.contains(ext) {
            return .raw
        }

        if ["heic", "heif"].contains(ext) {
            return .nativeHDR
        }

        return .sdr
    }
}

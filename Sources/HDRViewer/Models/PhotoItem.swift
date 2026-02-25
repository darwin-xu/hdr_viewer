import Foundation

enum PhotoSourceType {
    case nativeHDR
    case sdr
    case raw
}

enum HDRBoostMode {
    case none
    case sdr
    case raw
}

struct PhotoItem: Identifiable, Hashable {
    let id: URL
    let url: URL

    var fileName: String {
        url.lastPathComponent
    }

    var sourceType: PhotoSourceType {
        let ext = url.pathExtension.lowercased()

        if ["cr2", "cr3", "nef", "arw", "raf", "dng"].contains(ext) {
            return .raw
        }

        if ["heic", "heif"].contains(ext) {
            return .nativeHDR
        }

        return .sdr
    }
}

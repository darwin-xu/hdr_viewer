import Foundation

final class FolderIndex {
    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heif", "heic",
        "dng", "cr2", "cr3", "nef", "arw", "raf"
    ]

    func listPhotos(in folderURL: URL) throws -> [PhotoItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { isSupportedFile($0) }
            .map { PhotoItem(id: $0, url: $0) }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private func isSupportedFile(_ url: URL) -> Bool {
        guard
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            resourceValues.isRegularFile == true
        else {
            return false
        }

        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
}

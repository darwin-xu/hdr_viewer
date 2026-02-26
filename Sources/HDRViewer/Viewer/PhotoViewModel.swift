import AppKit
import CoreImage
import Foundation

enum ZoomCommand {
    case zoomIn
    case zoomOut
    case reset
}

@MainActor
final class PhotoViewModel: ObservableObject {
    private static let startPointDefaultsKey = "hdrViewer.treeStartPoints"

    @Published private(set) var photos: [PhotoItem] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var currentImage: NSImage?
    @Published private(set) var currentCIImage: CIImage?
    @Published private(set) var currentMetadata: PhotoMetadata?
    @Published private(set) var currentFolderURL: URL?
    @Published private(set) var treeStartPoints: [URL] = []
    @Published private(set) var selectedTreeFolderURL: URL?
    @Published var zoomCommand: ZoomCommand?
    @Published var lastErrorMessage: String?

    private let folderIndex: FolderIndex
    private let decodeService: ImageDecodeService
    private let cache: ImageCache
    private let metadataService: MetadataService
    private let log = Logger.shared

    init(
        folderIndex: FolderIndex,
        decodeService: ImageDecodeService,
        cache: ImageCache,
        metadataService: MetadataService
    ) {
        self.folderIndex = folderIndex
        self.decodeService = decodeService
        self.cache = cache
        self.metadataService = metadataService
        loadPersistedStartPoints()
    }

    var currentPhoto: PhotoItem? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    func addStartPointPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        if panel.runModal() == .OK, let folder = panel.url {
            addStartPoint(folder)
        }
    }

    func addStartPoint(_ folderURL: URL) {
        let normalizedURL = folderURL.standardizedFileURL

        if !treeStartPoints.contains(normalizedURL) {
            treeStartPoints.append(normalizedURL)
            treeStartPoints.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            persistStartPoints()
        }

        selectFolderFromTree(normalizedURL)
    }

    func selectFolderFromTree(_ folderURL: URL) {
        let normalizedURL = folderURL.standardizedFileURL
        selectedTreeFolderURL = normalizedURL
        loadFolder(normalizedURL)
    }

    func subfolders(for folderURL: URL) -> [URL] {
        folderIndex.listSubfolders(in: folderURL)
    }

    func hasSubfolders(for folderURL: URL) -> Bool {
        folderIndex.hasSubfolders(in: folderURL)
    }

    func openFolderPicker() {
        addStartPointPicker()
    }

    func zoomInRequest() {
        zoomCommand = .zoomIn
    }

    func zoomOutRequest() {
        zoomCommand = .zoomOut
    }

    func resetZoomRequest() {
        zoomCommand = .reset
    }

    func loadFolder(_ folderURL: URL) {
        log.info("Loading folder: \(folderURL.path)", source: "ViewModel")
        do {
            let items = try folderIndex.listPhotos(in: folderURL)
            currentFolderURL = folderURL
            photos = items
            currentIndex = 0
            cache.clear()
            log.info("Found \(items.count) photo(s) in \(folderURL.lastPathComponent)", source: "ViewModel")

            guard !items.isEmpty else {
                currentImage = nil
                currentCIImage = nil
                currentMetadata = nil
                return
            }

            Task {
                await loadCurrentImage()
            }
        } catch {
            log.error("loadFolder failed: \(error.localizedDescription)", source: "ViewModel")
            lastErrorMessage = error.localizedDescription
        }
    }

    func selectPhoto(_ item: PhotoItem) {
        guard let index = photos.firstIndex(of: item) else { return }
        currentIndex = index
        Task {
            await loadCurrentImage()
        }
    }

    func moveNext() {
        guard !photos.isEmpty else { return }
        currentIndex = min(currentIndex + 1, photos.count - 1)
        Task {
            await loadCurrentImage()
        }
    }

    func movePrevious() {
        guard !photos.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        Task {
            await loadCurrentImage()
        }
    }

    private func loadCurrentImage() async {
        guard let photo = currentPhoto else { return }
        let fileName = photo.fileName
        log.debug("loadCurrentImage: \(fileName)", source: "ViewModel")

        if let cached = cache.image(for: photo.url) {
            log.debug("Using cached NSImage for \(fileName)", source: "ViewModel")
            currentImage = cached
        } else {
            do {
                let image = try decodeService.decodeImage(from: photo.url)
                cache.setImage(image, for: photo.url)
                currentImage = image
                log.info("Loaded NSImage for \(fileName): \(Int(image.size.width))x\(Int(image.size.height))", source: "ViewModel")
            } catch {
                currentImage = nil
                currentCIImage = nil
                log.error("Decode failed for \(fileName): \(error.localizedDescription)", source: "ViewModel")
                lastErrorMessage = "Decode failed: \(error.localizedDescription)"
            }
        }

        if let ciImage = try? decodeService.decodeCIImage(from: photo.url) {
            currentCIImage = ciImage
            log.debug("CIImage available for \(fileName)", source: "ViewModel")
        } else {
            currentCIImage = nil
            log.debug("No CIImage for \(fileName), will use NSImage fallback viewer", source: "ViewModel")
        }

        currentMetadata = metadataService.readMetadata(from: photo.url)
        preloadNeighbors()
    }

    private func preloadNeighbors() {
        let neighborIndexes = [currentIndex - 1, currentIndex + 1].filter { photos.indices.contains($0) }

        Task.detached(priority: .utility) { [photos, cache, decodeService] in
            for index in neighborIndexes {
                let photo = photos[index]
                if cache.image(for: photo.url) != nil { continue }
                if let image = try? decodeService.decodeImage(from: photo.url, maxPixelSize: 2500) {
                    cache.setImage(image, for: photo.url)
                }
            }
        }
    }

    private func loadPersistedStartPoints() {
        guard let paths = UserDefaults.standard.array(forKey: Self.startPointDefaultsKey) as? [String] else {
            treeStartPoints = []
            return
        }

        let existingURLs = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        treeStartPoints = Array(Set(existingURLs)).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func persistStartPoints() {
        let paths = treeStartPoints.map(\.path)
        UserDefaults.standard.set(paths, forKey: Self.startPointDefaultsKey)
    }
}

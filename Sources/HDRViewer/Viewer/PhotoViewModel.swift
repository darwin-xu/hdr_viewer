import AppKit
import Foundation

@MainActor
final class PhotoViewModel: ObservableObject {
    @Published private(set) var photos: [PhotoItem] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var currentImage: NSImage?
    @Published private(set) var currentMetadata: PhotoMetadata?
    @Published private(set) var currentFolderURL: URL?
    @Published var lastErrorMessage: String?

    private let folderIndex: FolderIndex
    private let decodeService: ImageDecodeService
    private let cache: ImageCache
    private let metadataService: MetadataService

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
    }

    var currentPhoto: PhotoItem? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        if panel.runModal() == .OK, let folder = panel.url {
            loadFolder(folder)
        }
    }

    func loadFolder(_ folderURL: URL) {
        do {
            let items = try folderIndex.listPhotos(in: folderURL)
            currentFolderURL = folderURL
            photos = items
            currentIndex = 0
            cache.clear()

            guard !items.isEmpty else {
                currentImage = nil
                currentMetadata = nil
                return
            }

            Task {
                await loadCurrentImage()
            }
        } catch {
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

        if let cached = cache.image(for: photo.url) {
            currentImage = cached
        } else {
            do {
                let image = try decodeService.decodeImage(from: photo.url)
                cache.setImage(image, for: photo.url)
                currentImage = image
            } catch {
                currentImage = nil
                lastErrorMessage = "Decode failed: \(error.localizedDescription)"
            }
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
}

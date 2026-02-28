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
    @Published private(set) var currentVideoURL: URL?
    @Published private(set) var currentVideoDuration: Double?
    @Published private(set) var currentMetadata: PhotoMetadata?
    @Published private(set) var currentFolderURL: URL?
    @Published private(set) var treeStartPoints: [URL] = []
    @Published private(set) var selectedTreeFolderURL: URL?
    @Published private(set) var isTranscoding = false
    @Published var zoomCommand: ZoomCommand?
    @Published var lastErrorMessage: String?

    private let folderIndex: FolderIndex
    private let decodeService: ImageDecodeService
    private let cache: ImageCache
    private let metadataService: MetadataService
    private let log = Logger.shared
    private var loadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?

    /// Debounce interval for decode when rapidly skimming thumbnails (seconds).
    private let decodeDebounce: UInt64 = 150_000_000 // 150ms

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
                currentVideoURL = nil
                currentMetadata = nil
                return
            }

            startLoadingCurrentImage()
        } catch {
            log.error("loadFolder failed: \(error.localizedDescription)", source: "ViewModel")
            lastErrorMessage = error.localizedDescription
        }
    }

    func selectPhoto(_ item: PhotoItem) {
        guard let index = photos.firstIndex(of: item) else { return }
        currentIndex = index
        startLoadingCurrentImage()
    }

    func moveNext() {
        guard !photos.isEmpty else { return }
        currentIndex = min(currentIndex + 1, photos.count - 1)
        startLoadingCurrentImage()
    }

    func movePrevious() {
        guard !photos.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        startLoadingCurrentImage()
    }

    private func startLoadingCurrentImage() {
        loadTask?.cancel()
        preloadTask?.cancel()
        // Kill any in-progress ffmpeg process immediately
        TranscodeService.shared.cancelCurrent()
        isTranscoding = false
        guard let photo = currentPhoto else { return }

        // --- Video path: no image decode needed ---
        if photo.isVideo {
            currentImage = nil
            currentCIImage = nil
            currentVideoURL = nil   // clear so UI doesn't show stale video
            currentVideoDuration = nil
            currentMetadata = nil   // clear stale metadata so view doesn't show wrong badge

            let url = photo.url
            let metadataService = self.metadataService
            let needsTranscode = TranscodeService.needsTranscode(url)

            if needsTranscode { isTranscoding = true }

            loadTask = Task {
                if needsTranscode {
                    log.debug("Starting transcode flow for \(photo.fileName)", source: "ViewModel")

                    // Probe accurate duration from the original file via ffprobe.
                    // This works on formats AVFoundation can't read (e.g. .insv).
                    let probedDuration = await Task.detached(priority: .utility) {
                        TranscodeService.shared.probeDuration(for: url)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let pd = probedDuration {
                        currentVideoDuration = pd
                    }

                    // --- Step 1: Try fast path (cache hit or remux) ---
                    do {
                        let fastURL = try await Task.detached(priority: .userInitiated) {
                            try TranscodeService.shared.tryFastPath(for: url)
                        }.value
                        guard !Task.isCancelled else { return }

                        if let fastURL {
                            // Remux or cache hit — play immediately
                            isTranscoding = false
                            currentVideoURL = fastURL
                            currentMetadata = metadataService.readMetadata(from: fastURL, overrideDuration: probedDuration)
                            log.info("Fast-path video ready for \(photo.fileName)", source: "ViewModel")
                            return
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        // tryFastPath failed (e.g. ffmpeg not found) —
                        // log the error but still attempt progressive transcode
                        log.error("Fast path failed for \(photo.fileName): \(error.localizedDescription)", source: "ViewModel")
                    }

                    guard !Task.isCancelled else { return }

                    // --- Step 2: Progressive transcode (re-encode) ---
                    // Start ffmpeg producing fragmented MP4 in background,
                    // start playback once the first fragments appear.
                    let transcodeService = TranscodeService.shared
                    let outputURL = transcodeService.outputURL(for: url)

                    log.info("Starting progressive re-encode for \(photo.fileName)", source: "ViewModel")

                    // Launch the background encode (runs until done or cancelled)
                    let encodeTask = Task.detached(priority: .userInitiated) {
                        try transcodeService.transcodeProgressively(for: url)
                    }

                    // Wait for the file to have enough data to start playback
                    // (at least 64KB means the first fragments are written)
                    let minBytes: UInt64 = 64 * 1024
                    let maxWait = 400  // 400 × 50ms = 20s max wait
                    var waited = 0
                    while waited < maxWait {
                        guard !Task.isCancelled else {
                            encodeTask.cancel()
                            return
                        }
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                           let size = attrs[.size] as? UInt64, size >= minBytes {
                            log.debug("Output file reached \(size) bytes after \(waited * 50)ms", source: "ViewModel")
                            break
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                        waited += 1
                    }

                    guard !Task.isCancelled else {
                        encodeTask.cancel()
                        return
                    }

                    // Check if we actually have data (timeout expired with no/too-small file)
                    let fileExists = FileManager.default.fileExists(atPath: outputURL.path)
                    let fileSize: UInt64 = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? UInt64) ?? 0

                    if !fileExists || fileSize < minBytes {
                        log.error("Transcode timed out for \(photo.fileName) (size=\(fileSize) after \(waited * 50)ms), waiting for completion…", source: "ViewModel")
                        // Wait for the full encode to finish instead of giving up
                        do {
                            _ = try await encodeTask.value
                        } catch is CancellationError {
                            return
                        } catch {
                            guard !Task.isCancelled else { return }
                            isTranscoding = false
                            log.error("Re-encode failed for \(photo.fileName): \(error.localizedDescription)", source: "ViewModel")
                            lastErrorMessage = "Transcode failed: \(error.localizedDescription)"
                            return
                        }
                    }

                    guard !Task.isCancelled else {
                        encodeTask.cancel()
                        return
                    }

                    // Start playback — ffmpeg may still be writing in the background
                    isTranscoding = false
                    currentVideoURL = outputURL
                    // Use ffprobe duration for metadata (AVFoundation can't read
                    // partial fragmented MP4 or .insv files accurately)
                    currentMetadata = metadataService.readMetadata(from: outputURL, overrideDuration: probedDuration)
                    log.info("Progressive playback started for \(photo.fileName), transcode continuing in background", source: "ViewModel")

                    // Wait for encode to finish (or be cancelled)
                    _ = try? await encodeTask.value
                } else {
                    // No transcode needed
                    currentVideoURL = url
                    currentMetadata = metadataService.readMetadata(from: url)
                    log.info("Loaded video metadata for \(photo.fileName), isHDR=\(currentMetadata?.isHDRVideo ?? false)", source: "ViewModel")
                }
            }
            return
        }

        // --- Image path ---
        currentVideoURL = nil

        // Show cached image immediately if available (no delay)
        if let cached = cache.image(for: photo.url) {
            currentImage = cached
            log.debug("Using cached NSImage for \(photo.fileName)", source: "ViewModel")
        }

        let url = photo.url
        let fileName = photo.fileName
        let decodeService = self.decodeService
        let cache = self.cache
        let metadataService = self.metadataService
        let debounce = self.decodeDebounce

        loadTask = Task {
            // Debounce: wait a short period before committing to expensive decode.
            // If user selects another photo within this window, this task gets cancelled.
            if cache.image(for: url) == nil {
                try? await Task.sleep(nanoseconds: debounce)
                guard !Task.isCancelled else { return }
            }

            log.debug("loadCurrentImage: \(fileName)", source: "ViewModel")

            // Decode NSImage off the main thread
            let nsImage: NSImage? = await Task.detached(priority: .userInitiated) {
                if let cached = cache.image(for: url) { return cached }
                return try? decodeService.decodeImage(from: url)
            }.value

            guard !Task.isCancelled else { return }

            if let nsImage {
                cache.setImage(nsImage, for: url)
                currentImage = nsImage
                log.info("Loaded NSImage for \(fileName): \(Int(nsImage.size.width))x\(Int(nsImage.size.height))", source: "ViewModel")
            } else if cache.image(for: url) == nil {
                currentImage = nil
                currentCIImage = nil
                log.error("Decode failed for \(fileName)", source: "ViewModel")
                lastErrorMessage = "Decode failed for \(fileName)"
                return
            }

            guard !Task.isCancelled else { return }

            // Decode CIImage off the main thread
            let ciImage: CIImage? = await Task.detached(priority: .userInitiated) {
                return try? decodeService.decodeCIImage(from: url)
            }.value

            guard !Task.isCancelled else { return }

            if let ciImage {
                currentCIImage = ciImage
                log.debug("CIImage available for \(fileName)", source: "ViewModel")
            } else {
                currentCIImage = nil
                log.debug("No CIImage for \(fileName), will use NSImage fallback viewer", source: "ViewModel")
            }

            currentMetadata = metadataService.readMetadata(from: url)

            // Only preload neighbors after the user has settled on a photo
            schedulePreloadNeighbors()
        }
    }

    private func schedulePreloadNeighbors() {
        preloadTask?.cancel()
        let currentIdx = currentIndex
        let photos = self.photos
        let cache = self.cache
        let decodeService = self.decodeService

        preloadTask = Task {
            // Wait a bit to ensure user has stopped navigating before preloading
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }

            let neighborIndexes = [currentIdx - 1, currentIdx + 1].filter { photos.indices.contains($0) }

            await Task.detached(priority: .utility) {
                for index in neighborIndexes {
                    guard !Task.isCancelled else { return }
                    let photo = photos[index]
                    guard !photo.isVideo else { continue } // skip preloading for video
                    if cache.image(for: photo.url) != nil { continue }
                    if let image = try? decodeService.decodeImage(from: photo.url, maxPixelSize: 2500) {
                        cache.setImage(image, for: photo.url)
                    }
                }
            }.value
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

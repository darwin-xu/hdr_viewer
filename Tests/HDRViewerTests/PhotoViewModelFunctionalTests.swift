import AppKit
import Foundation
import Testing
@testable import HDRViewer

@MainActor
struct PhotoViewModelFunctionalTests {
    @Test
    func loadsFolderAndNavigatesNextPrevious() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try createTestImage(at: tempDir.appendingPathComponent("001.png"))
        try createTestImage(at: tempDir.appendingPathComponent("002.png"))
        try createTestImage(at: tempDir.appendingPathComponent("003.png"))

        let viewModel = PhotoViewModel(
            folderIndex: FolderIndex(),
            decodeService: ImageDecodeService(),
            cache: ImageCache(),
            metadataService: MetadataService()
        )

        viewModel.loadFolder(tempDir)
        try await waitUntil(viewModel.currentImage != nil)

        #expect(viewModel.photos.count == 3)
        #expect(viewModel.currentPhoto?.fileName == "001.png")

        viewModel.moveNext()
        try await waitUntil(viewModel.currentPhoto?.fileName == "002.png")
        #expect(viewModel.currentPhoto?.fileName == "002.png")

        viewModel.movePrevious()
        try await waitUntil(viewModel.currentPhoto?.fileName == "001.png")
        #expect(viewModel.currentPhoto?.fileName == "001.png")
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - start > timeoutNanoseconds {
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createTestImage(at url: URL) throws {
        let width = 32
        let height = 32

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw ImageCreationError()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ImageCreationError()
        }
        try data.write(to: url)
    }
}

private struct TimeoutError: Error {}
private struct ImageCreationError: Error {}

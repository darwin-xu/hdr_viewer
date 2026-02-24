import Foundation
import Testing
@testable import HDRViewer

struct FolderIndexTests {
    @Test
    func listsOnlySupportedPhotoFiles() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileManager = FileManager.default
        let supported = ["a.jpg", "b.CR3", "c.NEF", "d.heic", "e.tiff"]
        let unsupported = ["x.txt", "y.json", "z.mp4"]

        for name in supported + unsupported {
            let url = tempDir.appendingPathComponent(name)
            fileManager.createFile(atPath: url.path, contents: Data("sample".utf8))
        }

        let index = FolderIndex()
        let items = try index.listPhotos(in: tempDir)
        let names = Set(items.map(\.fileName))

        #expect(names == Set(supported))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

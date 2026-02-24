import SwiftUI

struct MetadataPanelView: View {
    let photo: PhotoItem?
    let metadata: PhotoMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Metadata")
                .font(.headline)

            if let photo {
                Group {
                    row("File", photo.fileName)
                    row("Path", photo.url.path)
                    row("Size", dimensions)
                    row("Camera", metadata?.cameraModel ?? "-")
                    row("Lens", metadata?.lensModel ?? "-")
                    row("ISO", metadata?.iso.map(String.init) ?? "-")
                    row("Exposure", metadata?.exposureTime ?? "-")
                    row("Aperture", metadata?.fNumber.map { "f/\(String(format: "%.1f", $0))" } ?? "-")
                    row("Focal", metadata?.focalLength.map { "\(String(format: "%.0f", $0)) mm" } ?? "-")
                }
            } else {
                Text("No image selected")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var dimensions: String {
        guard let metadata, let width = metadata.width, let height = metadata.height else {
            return "-"
        }
        return "\(width) × \(height)"
    }

    private func row(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

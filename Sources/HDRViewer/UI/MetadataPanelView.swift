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
                }

                if photo.isVideo {
                    videoMetadataRows
                } else {
                    imageMetadataRows
                }
            } else {
                Text("No media selected")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Image-specific rows

    @ViewBuilder
    private var imageMetadataRows: some View {
        Group {
            row("Camera", metadata?.cameraModel ?? "-")
            row("Lens", metadata?.lensModel ?? "-")
            row("ISO", metadata?.iso.map(String.init) ?? "-")
            row("Exposure", metadata?.exposureTime ?? "-")
            row("Aperture", metadata?.fNumber.map { "f/\(String(format: "%.1f", $0))" } ?? "-")
            row("Focal", metadata?.focalLength.map { "\(String(format: "%.0f", $0)) mm" } ?? "-")
        }
    }

    // MARK: - Video-specific rows

    @ViewBuilder
    private var videoMetadataRows: some View {
        Group {
            row("Duration", formattedDuration)
            row("Frame Rate", metadata?.frameRate.map { "\(String(format: "%.2f", $0)) fps" } ?? "-")
            row("Video Codec", metadata?.videoCodec ?? "-")
            row("Audio Codec", metadata?.audioCodec ?? "-")
            row("Bit Rate", formattedBitRate)
            if let metadata, metadata.isHDRVideo {
                row("HDR", "Yes")
            }
        }
    }

    // MARK: - Helpers

    private var dimensions: String {
        guard let metadata, let width = metadata.width, let height = metadata.height else {
            return "-"
        }
        return "\(width) × \(height)"
    }

    private var formattedDuration: String {
        guard let duration = metadata?.duration else { return "-" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let fraction = duration - Double(Int(duration))
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return String(format: "%.1fs", Double(seconds) + fraction)
    }

    private var formattedBitRate: String {
        guard let rate = metadata?.videoBitRate else { return "-" }
        if rate >= 1_000_000 {
            return String(format: "%.1f Mbps", rate / 1_000_000)
        }
        return String(format: "%.0f kbps", rate / 1_000)
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

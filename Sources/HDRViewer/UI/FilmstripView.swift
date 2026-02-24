import SwiftUI

struct FilmstripView: View {
    let photos: [PhotoItem]
    let selected: PhotoItem?
    let onSelect: (PhotoItem) -> Void
    @StateObject private var thumbnailProvider = ThumbnailProvider()

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.12))

                            if let image = thumbnailProvider.thumbnails[photo.url] {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 92, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Image(systemName: "photo")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 92, height: 56)

                        Text(photo.fileName)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 92)
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected == photo ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture {
                        onSelect(photo)
                    }
                    .onAppear {
                        thumbnailProvider.requestThumbnail(for: photo.url)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

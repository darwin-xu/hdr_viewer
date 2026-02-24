import SwiftUI

struct ThumbnailGridView: View {
    let photos: [PhotoItem]
    let selected: PhotoItem?
    let onSelect: (PhotoItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(photos) { photo in
                    ThumbnailCellView(photo: photo, isSelected: selected == photo)
                        .onTapGesture {
                            onSelect(photo)
                        }
                }
            }
            .padding(8)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct ThumbnailCellView: View {
    let photo: PhotoItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))

                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 70)

            Text(photo.fileName)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}

import SwiftUI

struct FilmstripView: View {
    let photos: [PhotoItem]
    let selected: PhotoItem?
    let onSelect: (PhotoItem) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.12))

                            Image(systemName: "photo")
                                .font(.headline)
                                .foregroundStyle(.secondary)
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
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

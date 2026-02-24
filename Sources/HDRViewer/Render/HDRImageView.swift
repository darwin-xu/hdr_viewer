import AppKit
import SwiftUI

struct HDRImageView: View {
    let image: NSImage
    let zoomScale: CGFloat
    let panOffset: CGSize

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(zoomScale)
            .offset(panOffset)
            .drawingGroup()
    }
}

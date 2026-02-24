import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: PhotoViewModel
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero

    var body: some View {
        NavigationSplitView {
            FolderTreeSidebarView(viewModel: viewModel)
            .frame(minWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                topBar

                Divider()

                HStack(spacing: 0) {
                    viewerArea

                    Divider()

                    MetadataPanelView(photo: viewModel.currentPhoto, metadata: viewModel.currentMetadata)
                        .frame(width: 280)
                }

                Divider()

                FilmstripView(
                    photos: viewModel.photos,
                    selected: viewModel.currentPhoto,
                    onSelect: { item in
                        zoomScale = 1.0
                        panOffset = .zero
                        viewModel.selectPhoto(item)
                    }
                )
                .frame(height: 110)
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                viewModel.movePrevious()
            case .right:
                viewModel.moveNext()
            default:
                break
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.lastErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.lastErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.lastErrorMessage ?? "Unknown error")
        }
    }

    private var topBar: some View {
        HStack {
            Button("Add Start Point") {
                viewModel.addStartPointPicker()
            }

            if let folder = viewModel.currentFolderURL {
                Text(folder.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No folder selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("-") {
                zoomScale = max(0.1, zoomScale - 0.1)
            }
            .frame(width: 30)

            Button("+") {
                zoomScale = min(5.0, zoomScale + 0.1)
            }
            .frame(width: 30)

            Button("Reset") {
                zoomScale = 1.0
                panOffset = .zero
            }
        }
        .padding(10)
    }

    private var viewerArea: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.95)

                if let ciImage = viewModel.currentCIImage {
                    HDRMetalView(ciImage: ciImage, zoomScale: zoomScale, panOffset: panOffset)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .gesture(
                            DragGesture()
                                .onChanged { gesture in
                                    panOffset = gesture.translation
                                }
                        )
                } else {
                    Text("Open a folder to start")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

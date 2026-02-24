import SwiftUI

@main
struct HDRViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var viewModel = PhotoViewModel(
        folderIndex: FolderIndex(),
        decodeService: ImageDecodeService(),
        cache: ImageCache(),
        metadataService: MetadataService()
    )

    var body: some Scene {
        WindowGroup("HDR Viewer") {
            ContentView(viewModel: viewModel)
        }
        .commands {
            CommandMenu("File") {
                Button("Add Start Point") { viewModel.addStartPointPicker() }
                    .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            CommandMenu("Navigate") {
                Button("Previous Photo") { viewModel.movePrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Next Photo") { viewModel.moveNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }

            CommandMenu("View") {
                Button("Zoom In") { viewModel.zoomInRequest() }
                    .keyboardShortcut("=", modifiers: [.command])

                Button("Zoom Out") { viewModel.zoomOutRequest() }
                    .keyboardShortcut("-", modifiers: [.command])

                Button("Reset Zoom") { viewModel.resetZoomRequest() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

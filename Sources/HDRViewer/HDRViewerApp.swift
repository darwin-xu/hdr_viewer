import SwiftUI

@main
struct HDRViewerApp: App {
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
            CommandMenu("Navigate") {
                Button("Previous Photo") { viewModel.movePrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Next Photo") { viewModel.moveNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [])

                Divider()

                Button("Open Folder") { viewModel.openFolderPicker() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

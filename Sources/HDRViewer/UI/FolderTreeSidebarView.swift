import SwiftUI

struct FolderTreeSidebarView: View {
    @ObservedObject var viewModel: PhotoViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Folders")
                    .font(.headline)
                Spacer()
                Button("Add Start Point") {
                    viewModel.addStartPointPicker()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if viewModel.treeStartPoints.isEmpty {
                VStack(spacing: 10) {
                    Text("No start points")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Add Start Point") {
                        viewModel.addStartPointPicker()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.treeStartPoints, id: \.self) { startURL in
                        FolderTreeNodeRow(
                            folderURL: startURL,
                            selectedFolderURL: viewModel.selectedTreeFolderURL,
                            onSelect: { folder in viewModel.selectFolderFromTree(folder) },
                            childrenProvider: { folder in viewModel.subfolders(for: folder) },
                            hasChildrenProvider: { folder in viewModel.hasSubfolders(for: folder) }
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct FolderTreeNodeRow: View {
    let folderURL: URL
    let selectedFolderURL: URL?
    let onSelect: (URL) -> Void
    let childrenProvider: (URL) -> [URL]
    let hasChildrenProvider: (URL) -> Bool

    @State private var isExpanded = false
    @State private var hasLoadedChildren = false
    @State private var children: [URL] = []

    var body: some View {
        Group {
            if hasChildrenProvider(folderURL) {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children, id: \.self) { child in
                        FolderTreeNodeRow(
                            folderURL: child,
                            selectedFolderURL: selectedFolderURL,
                            onSelect: onSelect,
                            childrenProvider: childrenProvider,
                            hasChildrenProvider: hasChildrenProvider
                        )
                    }
                } label: {
                    folderLabel
                }
                .onChange(of: isExpanded) { _, expanded in
                    guard expanded, !hasLoadedChildren else { return }
                    children = childrenProvider(folderURL)
                    hasLoadedChildren = true
                }
                .onAppear {
                    if selectedFolderURL == folderURL {
                        isExpanded = true
                    }
                }
            } else {
                folderLabel
            }
        }
    }

    private var folderLabel: some View {
        Button {
            onSelect(folderURL)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedFolderURL == folderURL ? "folder.fill" : "folder")
                Text(folderURL.lastPathComponent)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selectedFolderURL == folderURL ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

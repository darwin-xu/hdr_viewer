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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.treeStartPoints, id: \.self) { startURL in
                            FolderTreeNodeRow(
                                folderURL: startURL,
                                selectedFolderURL: viewModel.selectedTreeFolderURL,
                                onSelect: { folder in viewModel.selectFolderFromTree(folder) },
                                childrenProvider: { folder in viewModel.subfolders(for: folder) },
                                hasChildrenProvider: { folder in viewModel.hasSubfolders(for: folder) },
                                depth: 0
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .controlBackgroundColor))
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
    let depth: Int

    @State private var isExpanded = false
    @State private var hasLoadedChildren = false
    @State private var children: [URL] = []

    private var hasChildren: Bool { hasChildrenProvider(folderURL) }

    var body: some View {
        VStack(spacing: 0) {
            // Row
            HStack(spacing: 4) {
                // Disclosure chevron
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isExpanded.toggle()
                                loadChildrenIfNeeded()
                            }
                        }
                } else {
                    Spacer().frame(width: 12)
                }

                // Folder icon + name (tappable)
                Button {
                    onSelect(folderURL)
                    if hasChildren {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded = true
                            loadChildrenIfNeeded()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selectedFolderURL == folderURL ? "folder.fill" : "folder")
                            .font(.system(size: 12))
                        Text(folderURL.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(
                        selectedFolderURL == folderURL
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .foregroundStyle(selectedFolderURL == folderURL ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 16)

            // Children
            if isExpanded {
                ForEach(children, id: \.self) { child in
                    FolderTreeNodeRow(
                        folderURL: child,
                        selectedFolderURL: selectedFolderURL,
                        onSelect: onSelect,
                        childrenProvider: childrenProvider,
                        hasChildrenProvider: hasChildrenProvider,
                        depth: depth + 1
                    )
                }
            }
        }
        .onAppear {
            if selectedFolderURL == folderURL, hasChildren {
                isExpanded = true
                loadChildrenIfNeeded()
            }
        }
    }

    private func loadChildrenIfNeeded() {
        guard !hasLoadedChildren else { return }
        children = childrenProvider(folderURL)
        hasLoadedChildren = true
    }
}

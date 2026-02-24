import Foundation

struct PhotoItem: Identifiable, Hashable {
    let id: URL
    let url: URL

    var fileName: String {
        url.lastPathComponent
    }
}

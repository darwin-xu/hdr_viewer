import AVFoundation
import AVKit
import SwiftUI

/// A SwiftUI wrapper around AVPlayerView for video playback.
/// Does NOT autoplay — the user presses play manually.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        view.player = player
        context.coordinator.currentURL = url
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Only replace the player item when the URL actually changes
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            nsView.player?.pause()
            nsView.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var currentURL: URL?
    }
}

import AVFoundation
import AVKit
import SwiftUI

/// AppKit's AVPlayerView, which plays local files reliably and has a built-in trimming UI.
struct PlayerView: NSViewRepresentable {
    let url: URL
    let trimStart: Double?
    let trimEnd: Double?
    /// Pauses playback while false (e.g. while Cocut is recording).
    let isActive: Bool
    /// Bump to open AVPlayerView's trim bar.
    let trimRequest: Int
    let onTrimmed: (_ start: Double?, _ end: Double?) -> Void

    final class Coordinator {
        var url: URL?
        var trimRequest = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.url != url {
            coordinator.url = url
            coordinator.trimRequest = trimRequest
            let item = AVPlayerItem(url: url)
            if let trimStart {
                item.reversePlaybackEndTime = CMTime(seconds: trimStart, preferredTimescale: 600)
            }
            if let trimEnd {
                item.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
            }
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            view.player = player
            if let trimStart {
                player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Don't start playing on its own; the user presses play.
        }

        if !isActive {
            view.player?.pause()
        }

        if coordinator.trimRequest != trimRequest {
            coordinator.trimRequest = trimRequest
            guard view.canBeginTrimming else { return }
            view.player?.pause()
            view.beginTrimming { result in
                guard result == .okButton, let item = view.player?.currentItem else { return }
                let start = item.reversePlaybackEndTime
                let end = item.forwardPlaybackEndTime
                onTrimmed(start.isValid ? start.seconds : nil, end.isValid ? end.seconds : nil)
            }
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }
}

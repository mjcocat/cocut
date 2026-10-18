import AVFoundation
import AppKit

/// Generates and caches a poster frame for each clip.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private var cache: [URL: CGImage] = [:]

    func thumbnail(for url: URL) async -> CGImage? {
        if let cached = cache[url] { return cached }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 405)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)

        let duration = (try? await asset.load(.duration)) ?? .zero
        // A third of the way in usually lands on action rather than a pre-play frame.
        let time = duration.seconds.isFinite && duration.seconds > 0
            ? CMTime(seconds: duration.seconds * 0.33, preferredTimescale: 600)
            : .zero

        guard let result = try? await generator.image(at: time) else { return nil }
        cache[url] = result.image
        return result.image
    }

    func evict(_ url: URL) {
        cache[url] = nil
    }
}

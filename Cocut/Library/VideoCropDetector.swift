import AVFoundation
import CoreGraphics

/// Finds the video inside a screen recording: the part of the picture that actually changes.
/// With the cursor hidden and Cocut's own windows left out, a full-screen recording of a browser
/// only moves inside the video, so the changing area *is* the video. Static black bars around it
/// don't change either, so they're excluded too.
enum VideoCropDetector {
    /// Returns the moving area in the file's pixel coordinates (top-left origin), or nil when the
    /// whole frame moves (nothing to crop) or nothing clear was found.
    static func detect(url: URL) async -> CGRect? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let preferred = try? await track.load(.preferredTransform), preferred.isIdentity,
              let duration = try? await asset.load(.duration).seconds, duration > 0.5 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        let samples = 14
        var previous: [UInt8]?
        var changes: [UInt8] = []
        var width = 0, height = 0
        for i in 0..<samples {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(samples), preferredTimescale: 600)
            guard let image = try? await generator.image(at: t).image,
                  let gray = grayscale(image) else { continue }
            if width == 0 {
                width = image.width
                height = image.height
                changes = [UInt8](repeating: 0, count: width * height)
            }
            guard image.width == width, image.height == height else { continue }
            if let previous {
                for k in 0..<gray.count where abs(Int(gray[k]) - Int(previous[k])) > 18 {
                    if changes[k] < 255 { changes[k] += 1 }
                }
            }
            previous = gray
        }
        guard width > 16, height > 16 else { return nil }

        // A pixel counts as "video" if it changed between at least two pairs of samples.
        var rowHits = [Int](repeating: 0, count: height)
        var colHits = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where changes[row + x] >= 2 {
                rowHits[y] += 1
                colHits[x] += 1
            }
        }
        let rowMin = max(2, width / 60), colMin = max(2, height / 60)
        guard let top = rowHits.firstIndex(where: { $0 >= rowMin }),
              let bottom = rowHits.lastIndex(where: { $0 >= rowMin }),
              let left = colHits.firstIndex(where: { $0 >= colMin }),
              let right = colHits.lastIndex(where: { $0 >= colMin }),
              bottom > top, right > left else { return nil }

        let sx = natural.width / CGFloat(width), sy = natural.height / CGFloat(height)
        var rect = CGRect(x: CGFloat(left) * sx, y: CGFloat(top) * sy,
                          width: CGFloat(right - left + 1) * sx, height: CGFloat(bottom - top + 1) * sy)
        // Sampling is coarse: grow by a pixel or two of the sample grid, then keep it inside the frame.
        rect = rect.insetBy(dx: -sx, dy: -sy)
            .intersection(CGRect(origin: .zero, size: natural))
            .integral
        rect.origin.x -= rect.origin.x.truncatingRemainder(dividingBy: 2)
        rect.origin.y -= rect.origin.y.truncatingRemainder(dividingBy: 2)
        rect.size.width -= rect.size.width.truncatingRemainder(dividingBy: 2)
        rect.size.height -= rect.size.height.truncatingRemainder(dividingBy: 2)

        let share = (rect.width * rect.height) / (natural.width * natural.height)
        // Almost the whole frame moves: it's already just the video. Tiny: not trustworthy.
        guard share < 0.9, share > 0.06, rect.width >= 160, rect.height >= 90 else { return nil }
        return rect
    }

    private static func grayscale(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }
}

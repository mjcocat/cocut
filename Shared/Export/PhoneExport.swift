import AVFoundation
import CoreImage
import SwiftUI

/// The shape of the exported video: widescreen, or phone-shaped for social apps.
enum ReelShape: String, Codable, CaseIterable, Identifiable {
    case widescreen, vertical, portrait
    var id: String { rawValue }

    var title: String {
        switch self {
        case .widescreen: return "Widescreen 16:9"
        case .vertical: return "Phone 9:16"
        case .portrait: return "Feed 4:5"
        }
    }

    var detail: String {
        switch self {
        case .widescreen: return "For YouTube, email and recruiting sites."
        case .vertical: return "Full-screen on phones: Reels, TikTok, YouTube Shorts and Stories."
        case .portrait: return "Instagram and Facebook feeds. Keeps more of the court than 9:16."
        }
    }

    var isPhone: Bool { self != .widescreen }

    /// Width over height.
    var aspect: CGFloat {
        switch self {
        case .widescreen: return 16 / 9
        case .vertical: return 9 / 16
        case .portrait: return 4 / 5
        }
    }

    /// Phone shapes export 1080 wide.
    var phoneSize: CGSize {
        switch self {
        case .widescreen: return CGSize(width: 1920, height: 1080)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .portrait: return CGSize(width: 1080, height: 1350)
        }
    }
}

/// How a clip fills a phone-shaped frame.
enum PhoneFraming: String, Codable, CaseIterable, Identifiable {
    /// Follow the spotlighted player; clips without a spotlight use the export's choice.
    case automatic
    /// A still frame on the middle of the picture.
    case centered
    /// The whole picture, on a blurred fill.
    case wholePicture
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .centered: return "Centered"
        case .wholePicture: return "Whole Picture"
        }
    }
}

/// How one piece of the reel fills a phone frame.
enum SegmentFraming: Sendable {
    /// The frame looks at a (moving or fixed) center, in `CameraPath` coordinates.
    case window(CameraPath)
    /// The whole picture, fitted, over a blurred and darkened copy that fills the frame.
    case whole
}

// MARK: - Framing a clip

extension ReelExporter {
    /// How `clip` fills a phone frame: following the spotlighted player (tracked once, then
    /// remembered in the project), a centered frame, or the whole picture.
    static func phoneFraming(for clip: Clip, url: URL, options: ExportOptions, renderSize: CGSize,
                             cacheDirectory: URL, status: (String) -> Void) async -> SegmentFraming {
        let choice = clip.phoneFraming ?? .automatic
        switch choice {
        case .centered:
            return .window(.fixed(x: 0.5, y: 0.5))
        case .wholePicture:
            return .whole
        case .automatic:
            guard options.followSpotlight, let spot = clip.spotlight else {
                return options.unspotlitFraming == .wholePicture ? .whole : .window(.fixed(x: 0.5, y: 0.5))
            }
            status("Following the player in “\(clip.title)”…")
            guard let tracked = await trackedPlayer(clip: clip, url: url, spot: spot, cacheDirectory: cacheDirectory) else {
                return .window(.fixed(x: spot.x, y: spot.y))
            }
            let window = CameraPlanner.window(picture: (Double(tracked.width), Double(tracked.height)),
                                              output: (Double(renderSize.width), Double(renderSize.height)))
            let path = CameraPlanner.plan(sightings: tracked.sightings, start: clip.trimStartSeconds,
                                          end: clip.trimEndSeconds, window: window, fallback: (spot.x, spot.y))
            Log.info("Phone framing: followed the player in \(clip.fileName) (\(tracked.sightings.count) sightings)")
            return .window(path)
        }
    }

    /// Where the spotlighted player is through the clip, from the project's cache or tracked now.
    private static func trackedPlayer(clip: Clip, url: URL, spot: Spotlight,
                                      cacheDirectory: URL) async -> TrackedPlayer? {
        let crop = clip.unitCrop
        let key = [clip.trimStartSeconds, clip.trimEndSeconds, spot.x, spot.y, spot.radius,
                   Double(crop?.minX ?? 0), Double(crop?.minY ?? 0), Double(crop?.width ?? 1), Double(crop?.height ?? 1)]
            .map { String(format: "%.4f", $0) }.joined(separator: "_")
        let file = cacheDirectory.appending(path: "\(clip.id.uuidString)-\(TrackedPlayer.version).json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(TrackedPlayer.self, from: data),
           cached.key == key {
            return cached
        }
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let natural = try await track.load(.naturalSize)
            let preferred = try await track.load(.preferredTransform)
            let upright = CGRect(origin: .zero, size: natural).applying(preferred).size
            let cropFraction = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let sightings = try await PlayerTracker.follow(url: url, start: clip.trimStartSeconds, end: clip.trimEndSeconds,
                                                           unitCrop: crop, spot: spot)
            let tracked = TrackedPlayer(key: key, width: abs(upright.width) * cropFraction.width,
                                        height: abs(upright.height) * cropFraction.height, sightings: sightings)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(tracked) { try? data.write(to: file, options: .atomic) }
            return tracked
        } catch {
            Log.error("Couldn't follow the player in \(clip.fileName): \(error.localizedDescription)")
            return nil
        }
    }
}

/// A clip's tracked player, saved so later exports and previews don't track again.
struct TrackedPlayer: Codable {
    static let version = 1
    /// What it was tracked for (trim, spotlight, crop); a change means tracking again.
    var key: String
    /// Size of the spotlight's picture, in pixels.
    var width: CGFloat
    var height: CGFloat
    var times: [Double]
    var xs: [Double]
    var ys: [Double]

    init(key: String, width: CGFloat, height: CGFloat, sightings: [CameraPlanner.Sighting]) {
        self.key = key
        self.width = width
        self.height = height
        times = sightings.map(\.time)
        xs = sightings.map(\.x)
        ys = sightings.map(\.y)
    }

    var sightings: [CameraPlanner.Sighting] {
        zip(times, zip(xs, ys)).map { .init(time: $0, x: $1.0, y: $1.1) }
    }
}

// MARK: - Compositor

/// One piece of the reel on one source track, as the phone compositor draws it.
struct PhoneLayer: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    /// How to turn the stored frames upright.
    let orientation: CGImagePropertyOrientation
    /// The picture to show (upright pixels, top-left origin); nil is the whole frame.
    let picture: CGRect?
    /// What the camera path's fractions refer to (the spotlight's picture); nil is the whole frame.
    let pathSpace: CGRect?
    let framing: SegmentFraming
    /// When the piece starts on the reel, and the source time there.
    let timelineStart: Double
    let sourceStart: Double
    /// Fading out (a crossfade into the next piece): from and to on the reel.
    var fadeOut: (start: Double, end: Double)?

    func opacity(at time: Double) -> CGFloat {
        guard let fadeOut, fadeOut.end > fadeOut.start else { return 1 }
        let p = (time - fadeOut.start) / (fadeOut.end - fadeOut.start)
        return CGFloat(1 - min(1, max(0, p)))
    }
}

/// A stretch of the reel and the pieces in it (bottom first).
final class PhoneInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [PhoneLayer]

    init(timeRange: CMTimeRange, layers: [PhoneLayer], postProcessing: Bool) {
        self.timeRange = timeRange
        self.layers = layers
        enablePostProcessing = postProcessing
        requiredSourceTrackIDs = Array(Set(layers.map(\.trackID))).map { NSNumber(value: $0) }
    }
}

/// Draws phone-shaped reel frames with Core Image: each clip through its moving window (or the
/// whole picture on a blurred fill), crossfades between them.
final class PhoneCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "Cocut.PhoneCompositor", qos: .userInitiated)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? PhoneInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Cocut.PhoneCompositor", code: 1))
                return
            }
            let size = request.renderContext.size
            let bounds = CGRect(origin: .zero, size: size)
            let time = request.compositionTime.seconds
            var image = CIImage(color: .black).cropped(to: bounds)
            for layer in instruction.layers {
                guard let source = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                var frame = PhoneFrame.draw(layer, source: source, time: time, size: size)
                let alpha = layer.opacity(at: time)
                if alpha < 1 {
                    frame = frame.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                }
                image = frame.composited(over: image)
            }
            context.render(image.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// One source frame turned into a phone-shaped picture.
enum PhoneFrame {
    static func draw(_ layer: PhoneLayer, source: CVPixelBuffer, time: Double, size: CGSize) -> CIImage {
        var image = CIImage(cvPixelBuffer: source)
        if layer.orientation != .up { image = image.oriented(layer.orientation) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let full = CGRect(origin: .zero, size: image.extent.size)
        let height = full.height
        let picture = (layer.picture ?? full).intersection(full).isEmpty ? full : (layer.picture ?? full).intersection(full)
        // Core Image's origin is bottom-left.
        func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }

        switch layer.framing {
        case .whole:
            let shown = image.cropped(to: flipped(picture))
                .transformed(by: CGAffineTransform(translationX: -picture.minX, y: -(height - picture.maxY)))
            let fill = max(size.width / picture.width, size.height / picture.height)
            let fit = min(size.width / picture.width, size.height / picture.height)
            let background = shown.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: fill, y: fill)
                    .concatenating(CGAffineTransform(translationX: (size.width - picture.width * fill) / 2,
                                                     y: (size.height - picture.height * fill) / 2)))
                .applyingGaussianBlur(sigma: 40 * size.width / 1080)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.1])
                .cropped(to: CGRect(origin: .zero, size: size))
            let front = shown
                .transformed(by: CGAffineTransform(scaleX: fit, y: fit)
                    .concatenating(CGAffineTransform(translationX: (size.width - picture.width * fit) / 2,
                                                     y: (size.height - picture.height * fit) / 2)))
            return front.composited(over: background)

        case .window(let path):
            let center = path.center(at: layer.sourceStart + (time - layer.timelineStart))
            let space = layer.pathSpace ?? full
            // The phone frame's size in picture pixels: full height (or width), the output's shape.
            let aspect = size.width / size.height
            let w: CGFloat, h: CGFloat
            if picture.width / picture.height > aspect {
                h = picture.height
                w = h * aspect
            } else {
                w = picture.width
                h = w / aspect
            }
            var cx = space.minX + CGFloat(center.x) * space.width
            var cy = space.minY + CGFloat(center.y) * space.height
            cx = min(picture.maxX - w / 2, max(picture.minX + w / 2, cx))
            cy = min(picture.maxY - h / 2, max(picture.minY + h / 2, cy))
            let window = flipped(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            let scale = size.width / w
            return image.cropped(to: window)
                .transformed(by: CGAffineTransform(translationX: -window.minX, y: -window.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        }
    }
}

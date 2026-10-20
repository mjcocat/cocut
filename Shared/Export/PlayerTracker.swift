import AVFoundation
import CoreML
import Vision

/// Follows the spotlighted player through a clip, for phone exports: finds them on the first
/// frame from the spotlight ring, follows them with Vision's object tracker, and when the
/// tracker loses them (players cross, someone runs in front) finds them again by how they look,
/// with the same re-identification model Find Rallies uses. A check every second catches the
/// tracker quietly sliding onto a teammate.
enum PlayerTracker {
    /// How often frames are looked at.
    static let interval = 0.1
    /// Below this, the tracker is guessing.
    static let minConfidence: Float = 0.35
    /// Appearance agreement needed to say "that's them again".
    static let sameLook: Float = 0.55

    /// Where the player is through `start...end` (clip seconds), in the picture the spotlight was
    /// placed on: the upright frame, cropped to `unitCrop` (fractions of it) when the clip has one.
    static func follow(url: URL, start: Double, end: Double, unitCrop: CGRect?,
                       spot: Spotlight) async throws -> [CameraPlanner.Sighting] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let orientation = Self.orientation(of: preferred)
        let upright = CGRect(origin: .zero, size: natural).applying(preferred).size
        let width = abs(upright.width), height = abs(upright.height)
        guard width > 0, height > 0 else { return [] }
        let crop = unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let picture = PictureSpace(crop: crop)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        let sequence = VNSequenceRequestHandler()
        var current: VNDetectedObjectObservation?
        var look: [Float]?
        var seeded = false
        var sightings: [CameraPlanner.Sighting] = []
        var lastFrame = -Double.infinity, lastCheck = -Double.infinity, lastSearch = -Double.infinity
        var lastCenter = picture.toVision(x: spot.x, y: spot.y)

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time - lastFrame >= interval - 0.005 else { continue }
            lastFrame = time

            if current == nil {
                if !seeded {
                    seeded = true
                    // First frame: the person inside the ring, or a box the ring's size.
                    let seed = seedBox(buffer: buffer, orientation: orientation, spot: spot, picture: picture,
                                       aspect: width / height)
                    current = VNDetectedObjectObservation(boundingBox: seed)
                    look = appearance(buffer: buffer, orientation: orientation, box: seed)
                } else if time - lastSearch >= 0.3 {
                    // Lost: look for them again.
                    lastSearch = time
                    if let found = reacquire(buffer: buffer, orientation: orientation, look: look, near: lastCenter) {
                        current = VNDetectedObjectObservation(boundingBox: found)
                    }
                }
                if let box = current?.boundingBox {
                    lastCenter = CGPoint(x: box.midX, y: box.midY)
                    let p = picture.fromVision(lastCenter)
                    sightings.append(.init(time: time, x: p.x, y: p.y))
                }
                continue
            }

            let request = VNTrackObjectRequest(detectedObjectObservation: current!)
            request.trackingLevel = .accurate
            do {
                try sequence.perform([request], on: buffer, orientation: orientation)
            } catch {
                current = nil
                continue
            }
            guard let result = request.results?.first as? VNDetectedObjectObservation,
                  result.confidence >= minConfidence else {
                current = nil
                continue
            }
            // Once a second: is it still them? Trackers can slide onto a teammate who crosses.
            if time - lastCheck >= 1, let look {
                lastCheck = time
                if let now = appearance(buffer: buffer, orientation: orientation, box: result.boundingBox),
                   dot(now, look) < sameLook - 0.15 {
                    current = nil
                    continue
                }
            }
            current = result
            lastCenter = CGPoint(x: result.boundingBox.midX, y: result.boundingBox.midY)
            let p = picture.fromVision(lastCenter)
            sightings.append(.init(time: time, x: p.x, y: p.y))
        }
        // Keep only sightings inside the picture (the tracker can wander off the crop).
        return sightings.filter { (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }
    }

    // MARK: Pieces

    /// Converts between the spotlight's picture (top-left fractions of the cropped upright frame)
    /// and Vision's normalized upright frame (bottom-left origin).
    struct PictureSpace {
        let crop: CGRect

        func toVision(x: Double, y: Double) -> CGPoint {
            CGPoint(x: crop.minX + x * crop.width, y: 1 - (crop.minY + y * crop.height))
        }

        func fromVision(_ p: CGPoint) -> (x: Double, y: Double) {
            ((p.x - crop.minX) / max(crop.width, 0.0001), ((1 - p.y) - crop.minY) / max(crop.height, 0.0001))
        }
    }

    /// The person under the spotlight on the first frame, or a box the ring's size around it.
    private static func seedBox(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, spot: Spotlight,
                                picture: PictureSpace, aspect: CGFloat) -> CGRect {
        let center = picture.toVision(x: spot.x, y: spot.y)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try? handler.perform([request])
        let people = (request.results ?? []).map(\.boundingBox)
        func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - center.x, (r.midY - center.y) / aspect) }
        if let inside = people.filter({ $0.insetBy(dx: -0.01, dy: -0.01).contains(center) }).min(by: { distance($0) < distance($1) }) {
            return inside
        }
        // The ring's height is the player's height, roughly; a player is about half as wide.
        let h = min(0.9, spot.radius * 2.2 * picture.crop.height)
        let w = h * 0.45 / aspect
        let ring = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        if let near = people.min(by: { distance($0) < distance($1) }), distance(near) < h / 2 {
            return near
        }
        return ring.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The best match for `look` among the people in the frame, close enough to where they were.
    private static func reacquire(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                  look: [Float]?, near: CGPoint) -> CGRect? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try? handler.perform([request])
        let people = (request.results ?? []).map(\.boundingBox)
            .filter { hypot($0.midX - near.x, $0.midY - near.y) < 0.35 }
        guard !people.isEmpty else { return nil }
        guard let look, let model = ReIDModel.shared else {
            // No appearance model: the nearest person, only when they're quite close.
            let nearest = people.min { hypot($0.midX - near.x, $0.midY - near.y) < hypot($1.midX - near.x, $1.midY - near.y) }
            return nearest.flatMap { hypot($0.midX - near.x, $0.midY - near.y) < 0.12 ? $0 : nil }
        }
        var best: (box: CGRect, score: Float)?
        for box in people {
            guard let print = ReIDModel.embedding(handler, region: box, model: model) else { continue }
            let similarity = dot(print, look)
            let score = similarity - Float(hypot(box.midX - near.x, box.midY - near.y))
            if similarity >= sameLook, score > (best?.score ?? -.infinity) { best = (box, score) }
        }
        return best?.box
    }

    private static func appearance(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, box: CGRect) -> [Float]? {
        guard let model = ReIDModel.shared else { return nil }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        return ReIDModel.embedding(handler, region: box, model: model)
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// How to turn a track's stored frames upright, from its preferred transform.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0, t.b == 1, t.c == -1, t.d == 0 { return .right }
        if t.a == 0, t.b == -1, t.c == 1, t.d == 0 { return .left }
        if t.a == -1, t.b == 0, t.c == 0, t.d == -1 { return .down }
        return .up
    }
}

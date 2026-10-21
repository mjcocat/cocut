import AVFoundation
import CoreML
import Vision

/// Follows the spotlighted player through a clip, for phone exports. It looks through the whole
/// clip first, 15 frames a second: the people in each frame (body pose and person rectangles, as
/// Find Rallies finds them, which tells apart players standing together), every fourth frame the
/// jersey numbers it can read on them and how they look (the re-identification model Find
/// Rallies uses). Then `PlayerChain` works out which of them is the player across the whole clip,
/// starting from the spotlight ring and any clicks on their head.
enum PlayerTracker {
    /// How often frames are looked at.
    static let interval = 1.0 / 15
    /// Numbers and looks are taken on every this-many frames (they're slower than finding people).
    static let detailEvery = 4
    /// People shorter than this (a share of the picture's height) are too small for numbers or looks.
    static let detailMinHeight: CGFloat = 0.08

    /// Where the player is through `start...end` (clip seconds), in the picture the spotlight was
    /// placed on: the upright frame, cropped to `unitCrop` (fractions of it) when the clip has one.
    /// `number` is the jersey number they're expected to wear (from the player card), if known.
    static func follow(url: URL, start: Double, end: Double, unitCrop: CGRect?, spot: Spotlight?,
                       marks: [PlayerMark] = [], number: Int?) async throws -> [CameraPlanner.Sighting] {
        let clicks = marks.filter { $0.time >= start - 0.2 && $0.time <= end }
        guard spot != nil || !clicks.isEmpty else { return [] }
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

        // 1. Everyone in every frame.
        var frames: [PlayerChain.Frame] = []
        var problems: [String: Int] = [:]
        var reads: [Int: Int] = [:]
        var lastFrame = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time - lastFrame >= interval - 0.005 else { continue }
            lastFrame = time

            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
            let boxes = RallyDetector.playerBodies(handler, minHeight: 0.03, maxMidY: 1, problems: &problems)
                .map(\.box)
                .filter { crop.contains(CGPoint(x: $0.midX, y: 1 - $0.midY)) }
            let detail = frames.count % detailEvery == 0
            let people = boxes.map { r -> PlayerChain.Person in
                var person = PlayerChain.Person(x: Double(r.minX), y: Double(r.minY), width: Double(r.width),
                                                height: Double(r.height))
                if detail, r.height >= detailMinHeight {
                    person.number = readNumber(handler, box: r)
                    person.look = appearance(handler, box: r)
                    if let n = person.number { reads[n, default: 0] += 1 }
                }
                return person
            }
            frames.append(PlayerChain.Frame(time: time, people: people))
        }

        // 2. Who they are, across the whole clip.
        var anchors: [PlayerChain.Anchor] = []
        if let spot {
            let c = picture.toVision(x: spot.x, y: spot.y)
            anchors.append(.init(time: start, x: Double(c.x), y: Double(c.y), kind: .body))
        }
        for click in clicks {
            let c = picture.toVision(x: click.x, y: click.y)
            anchors.append(.init(time: click.time, x: Double(c.x), y: Double(c.y), kind: .head))
        }
        let path = PlayerChain.follow(frames, anchors: anchors, number: number, aspect: Double(width / height))
        let sightings = zip(frames, path).compactMap { frame, person -> CameraPlanner.Sighting? in
            guard let person else { return nil }
            let p = picture.fromVision(CGPoint(x: person.center.x, y: person.center.y))
            return .init(time: frame.time, x: p.x, y: p.y)
        }

        let people = frames.map(\.people.count).reduce(0, +)
        let numbers = reads.sorted { $0.value > $1.value }.prefix(8).map { "#\($0.key)×\($0.value)" }.joined(separator: " ")
        Log.info("Followed the player: in \(sightings.count) of \(frames.count) frames, "
                 + String(format: "%.1f people a frame", Double(people) / Double(max(1, frames.count)))
                 + (clicks.isEmpty ? "" : ", \(clicks.count) head click\(clicks.count == 1 ? "" : "s")")
                 + ", numbers read: \(numbers.isEmpty ? "none" : numbers)")
        if !problems.isEmpty { Log.error("Following the player: Vision problems \(problems)") }
        // Keep only sightings inside the picture.
        return sightings.filter { (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }
    }

    /// The jersey number on someone, read from the top part of their box (where the number is,
    /// front or back), if it can be read.
    private static func readNumber(_ handler: VNImageRequestHandler, box: CGRect) -> Int? {
        let region = CGRect(x: box.minX - box.width * 0.1, y: box.minY + box.height * 0.4,
                            width: box.width * 1.2, height: box.height * 0.55)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width > 0.005, region.height > 0.005 else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = region
        try? handler.perform([request])
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) where candidate.confidence >= 0.3 {
                if let n = RallyDetector.jerseyNumber(from: candidate.string) { return n }
            }
        }
        return nil
    }

    private static func appearance(_ handler: VNImageRequestHandler, box: CGRect) -> [Float]? {
        guard let model = ReIDModel.shared else { return nil }
        return ReIDModel.embedding(handler, region: box, model: model)
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

    /// How to turn a track's stored frames upright, from its preferred transform.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0, t.b == 1, t.c == -1, t.d == 0 { return .right }
        if t.a == 0, t.b == -1, t.c == 1, t.d == 0 { return .left }
        if t.a == -1, t.b == 0, t.c == 0, t.d == -1 { return .down }
        return .up
    }
}

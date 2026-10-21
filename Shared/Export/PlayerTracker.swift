import AVFoundation
import CoreML
import Vision

/// Follows the spotlighted player through a clip, for phone exports. Every frame (15 a second)
/// it finds the people in the picture with Vision (body pose and person rectangles, as Find
/// Rallies does, which tells apart players standing together), and `PlayerFollower` picks out the player:
/// by where they were heading and how big they look (a teammate passing between the camera and
/// the net looks far bigger), and when it's close, by the number on their back and how they look,
/// with the same re-identification model Find Rallies uses. Their number is checked every half
/// second; if it's wrong twice running, the follow goes back to the last time it was right and
/// looks for them again. When nobody found fits, Vision's object tracker (seeded from the last
/// good box, and held to the same size check) bridges the gap.
enum PlayerTracker {
    /// How often frames are looked at.
    static let interval = 1.0 / 15
    /// How often the number on the followed player's back is checked.
    static let numberCheck = 0.5

    /// Where the player is through `start...end` (clip seconds), in the picture the spotlight was
    /// placed on: the upright frame, cropped to `unitCrop` (fractions of it) when the clip has one.
    /// `number` is the jersey number they're expected to wear (from the player card), if known.
    static func follow(url: URL, start: Double, end: Double, unitCrop: CGRect?,
                       spot: Spotlight, number: Int?) async throws -> [CameraPlanner.Sighting] {
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

        var follower: PlayerFollower?
        var look: [Float]?
        let sequence = VNSequenceRequestHandler()
        var problems: [String: Int] = [:]
        var diag = (people: 0, empty: 0, bridged: 0, longestLost: 0.0)
        var sightings: [CameraPlanner.Sighting] = []
        var lastFrame = -Double.infinity, lastNumberCheck = -Double.infinity, lastSearch = -Double.infinity
        var stats = (frames: 0, found: 0, rewinds: 0, reads: 0)
        var lastRect: CGRect?

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time - lastFrame >= interval - 0.005 else { continue }
            lastFrame = time
            stats.frames += 1

            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
            let people = RallyDetector.playerBodies(handler, minHeight: 0.03, maxMidY: 1, problems: &problems)
                .map(\.box)
                .filter { crop.contains(CGPoint(x: $0.midX, y: 1 - $0.midY)) }
            diag.people += people.count
            if people.isEmpty { diag.empty += 1 }

            guard var current = follower else {
                // First frame: the person inside the ring, or a box the ring's size.
                let seed = seedBox(people: people, spot: spot, picture: picture, aspect: width / height)
                follower = PlayerFollower(seed: box(seed), time: time, aspect: width / height,
                                          number: number)
                look = appearance(handler, box: seed)
                sightings.append(sighting(seed, time: time, picture: picture))
                lastRect = seed
                continue
            }

            let boxes = people.map(box)
            let gated = current.gate(boxes, at: time)
            // When it's close (or they've been lost a while), read numbers and compare looks.
            var numbers: [Int: Int] = [:]
            var looks: [Int: Float] = [:]
            let lost = current.lostFor(at: time)
            if current.isAmbiguous(gated) || (lost > 0.3 && !gated.isEmpty && time - lastSearch >= 0.3) {
                lastSearch = time
                for g in gated.prefix(3) {
                    if current.number != nil, let n = readNumber(handler, box: people[g.index]) {
                        numbers[g.index] = n
                        stats.reads += 1
                    }
                    if let look, let now = appearance(handler, box: people[g.index]) { looks[g.index] = dot(now, look) }
                }
            }
            var rect: CGRect
            if let chosen = current.choose(gated, numbers: numbers, looks: looks) {
                rect = people[chosen]
            } else if let last = lastRect, current.lostFor(at: time) < 1.5,
                      let tracked = track(last, buffer: buffer, orientation: orientation, sequence: sequence),
                      !current.gate([box(tracked)], at: time).isEmpty {
                // Nobody found fits (hidden, or boxed together with someone): the object
                // tracker carries on from the last good box, if what it finds is the right size.
                rect = tracked
                diag.bridged += 1
            } else {
                diag.longestLost = max(diag.longestLost, current.lostFor(at: time))
                follower = current
                continue
            }
            current.update(box(rect), at: time)
            lastRect = rect
            stats.found += 1
            sightings.append(sighting(rect, time: time, picture: picture))

            // Every half second: is it still them? Read the number on their back.
            if time - lastNumberCheck >= numberCheck {
                lastNumberCheck = time
                let read = readNumber(handler, box: rect)
                if read != nil { stats.reads += 1 }
                if current.read(read, at: time) {
                    // Slid onto a teammate: drop what was followed since it was last surely
                    // them, and look for them again from there.
                    let since = current.rewind()
                    sightings.removeAll { $0.time > since }
                    lastRect = nil
                    stats.rewinds += 1
                }
            }
            follower = current
        }
        let seconds = max(0.001, end - start)
        Log.info("Followed the player: found in \(stats.found) of \(stats.frames) frames"
                 + " (\(diag.bridged) bridged by the tracker), \(String(format: "%.1f", Double(diag.people) / Double(max(1, stats.frames)))) people a frame,"
                 + " \(diag.empty) frames with nobody, longest lost \(String(format: "%.1f", diag.longestLost))s of \(String(format: "%.1f", seconds))s,"
                 + " \(stats.reads) number reads"
                 + (follower?.number.map { ", #\($0)\(follower?.numberConfirmed == true ? " confirmed" : " not seen")" } ?? "")
                 + (stats.rewinds > 0 ? ", caught \(stats.rewinds) slip\(stats.rewinds == 1 ? "" : "s") onto a teammate" : ""))
        if !problems.isEmpty { Log.error("Following the player: Vision problems \(problems)") }
        // Keep only sightings inside the picture.
        return sightings.filter { (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }
    }

    private static func box(_ r: CGRect) -> PlayerFollower.Box {
        PlayerFollower.Box(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    private static func sighting(_ r: CGRect, time: Double, picture: PictureSpace) -> CameraPlanner.Sighting {
        let p = picture.fromVision(CGPoint(x: r.midX, y: r.midY))
        return .init(time: time, x: p.x, y: p.y)
    }

    /// Where Vision's object tracker finds `last` in this frame, if it's fairly sure.
    private static func track(_ last: CGRect, buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                              sequence: VNSequenceRequestHandler) -> CGRect? {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: last))
        request.trackingLevel = .accurate
        guard (try? sequence.perform([request], on: buffer, orientation: orientation)) != nil,
              let result = request.results?.first as? VNDetectedObjectObservation,
              result.confidence >= 0.4 else { return nil }
        return result.boundingBox
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
    private static func seedBox(people: [CGRect], spot: Spotlight, picture: PictureSpace, aspect: CGFloat) -> CGRect {
        let center = picture.toVision(x: spot.x, y: spot.y)
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

    private static func appearance(_ handler: VNImageRequestHandler, box: CGRect) -> [Float]? {
        guard let model = ReIDModel.shared else { return nil }
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

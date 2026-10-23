import AVFoundation
import CoreImage
import Vision

/// Follows the spotlighted player through a clip, for phone exports. It looks through the whole
/// clip first, 15 frames a second: the people in each frame (body pose and person rectangles, as
/// Find Rallies finds them, which tells apart players standing together), and every fourth frame
/// the jersey numbers it can read on them. Then `PlayerChain` works out which of them is the player across the whole clip,
/// starting from the spotlight ring and any clicks on their head.
enum PlayerTracker {
    /// How often frames are looked at.
    static let interval = 1.0 / 15
    /// Numbers are read on every this-many frames (it's slower than finding people).
    static let detailEvery = 4
    /// People shorter than this (a share of the picture's height) are too small to read numbers on.
    static let detailMinHeight: CGFloat = 0.08

    typealias Detections = ClipDetections

    /// Where the player is through `start...end` (clip seconds), in the picture the spotlight was
    /// placed on: the upright frame, cropped to `unitCrop` (fractions of it) when the clip has one.
    /// `number` is the jersey number they're expected to wear (from the player card), if known.
    static func follow(url: URL, start: Double, end: Double, unitCrop: CGRect?, spot: Spotlight?,
                       marks: [PlayerMark] = [], number: Int?,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> [CameraPlanner.Sighting] {
        let clicks = marks.filter { $0.time >= start - 0.2 && $0.time <= end }
        guard spot != nil || !clicks.isEmpty else { return [] }
        guard let found = try await detect(url: url, start: start, end: end, unitCrop: unitCrop,
                                           progress: progress) else { return [] }
        let anchors = Self.anchors(spot: spot, marks: clicks, start: start, unitCrop: unitCrop)
        let path = PlayerChain.follow(found.frames, anchors: anchors, number: number, aspect: found.aspect)
        record(url: url, detections: found, anchors: anchors, number: number, path: path)

        let reads = found.frames.flatMap(\.people).compactMap(\.number)
            .reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        let people = found.frames.map(\.people.count).reduce(0, +)
        let numbers = reads.sorted { $0.value > $1.value }.prefix(8).map { "#\($0.key)×\($0.value)" }.joined(separator: " ")
        let sightings = Self.sightings(found, path: path)
        Log.info("Followed the player: in \(sightings.count) of \(found.frames.count) frames, "
                 + String(format: "%.1f people a frame", Double(people) / Double(max(1, found.frames.count)))
                 + (clicks.isEmpty ? "" : ", \(clicks.count) head click\(clicks.count == 1 ? "" : "s")")
                 + ", numbers read: \(numbers.isEmpty ? "none" : numbers)")
        if let problems = found.problems, !problems.isEmpty { Log.error("Following the player: Vision problems \(problems)") }
        return sightings
    }

    /// Where the spotlight ring and head clicks point, in Vision's coordinates.
    static func anchors(spot: Spotlight?, marks: [PlayerMark], start: Double, unitCrop: CGRect?) -> [PlayerChain.Anchor] {
        let picture = PictureSpace(crop: unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        var anchors: [PlayerChain.Anchor] = []
        if let spot {
            let c = picture.toVision(x: spot.x, y: spot.y)
            // At the spotlight's moment (the clip's start unless it was placed later).
            anchors.append(.init(time: max(start, spot.time ?? start), x: Double(c.x), y: Double(c.y), kind: .body))
        }
        for mark in marks {
            let c = picture.toVision(x: mark.x, y: mark.y)
            anchors.append(.init(time: mark.time, x: Double(c.x), y: Double(c.y), kind: .head))
        }
        return anchors
    }

    /// The followed path as camera sightings, in the clip's (cropped) picture.
    static func sightings(_ found: Detections, path: [PlayerChain.Person?]) -> [CameraPlanner.Sighting] {
        let picture = PictureSpace(crop: found.unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        return zip(found.frames, path).compactMap { frame, person -> CameraPlanner.Sighting? in
            guard let person else { return nil }
            let p = picture.fromVision(CGPoint(x: person.center.x, y: person.center.y))
            return .init(time: frame.time, x: p.x, y: p.y)
        }
        // Keep only sightings inside the picture.
        .filter { (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }
    }

    /// Everyone in every frame of `start...end`: the people (body pose and person rectangles, as
    /// Find Rallies finds them) and, every fourth frame, the numbers read on them. Nil when the
    /// clip has no readable video.
    static func detect(url: URL, start: Double, end: Double, unitCrop: CGRect?,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Detections? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let orientation = Self.orientation(of: preferred)
        let upright = CGRect(origin: .zero, size: natural).applying(preferred).size
        let width = abs(upright.width), height = abs(upright.height)
        guard width > 0, height > 0 else { return nil }
        let crop = unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var frames: [PlayerChain.Frame] = []
        var rawRectangles: [[[Double]]] = []
        var problems: [String: Int] = [:]
        var lastFrame = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time - lastFrame >= interval - 0.005 else { continue }
            lastFrame = time

            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
            var found = RallyDetector.playerBodies(handler, minHeight: 0.03, maxMidY: 1, problems: &problems).map(\.box)
            if found.count < Self.fewPeople {
                found += Self.halves(buffer, orientation: orientation, besides: found, problems: &problems)
            }
            let boxes = found.filter { crop.contains(CGPoint(x: $0.midX, y: 1 - $0.midY)) }
            let rectangles = VNDetectHumanRectanglesRequest()
            rectangles.upperBodyOnly = false
            try? handler.perform([rectangles])
            rawRectangles.append((rectangles.results ?? []).map {
                [Double($0.boundingBox.minX), Double($0.boundingBox.minY), Double($0.boundingBox.width), Double($0.boundingBox.height)]
            })
            let detail = frames.count % detailEvery == 0
            let people = boxes.map { r -> PlayerChain.Person in
                var person = PlayerChain.Person(x: Double(r.minX), y: Double(r.minY), width: Double(r.width),
                                                height: Double(r.height))
                if detail, r.height >= detailMinHeight { person.number = readNumber(handler, box: r) }
                return person
            }
            frames.append(PlayerChain.Frame(time: time, people: people))
            if end > start { progress?(min(1, (time - start) / (end - start))) }
        }
        return Detections(width: Double(width), height: Double(height), start: start, end: end,
                          crop: unitCrop.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
                          frames: frames, rectangles: rawRectangles, problems: problems.isEmpty ? nil : problems)
    }

    /// Fewer people than this in a frame (a volleyball court has twelve) means many were missed,
    /// usually because they're small in the picture (a wide shot, or 720p): look again at each half.
    static let fewPeople = 4

    /// People found in the left and right halves of the frame on their own (overlapping in the
    /// middle), who weren't found in the whole frame. The detector looks at a shrunken copy of
    /// what it's given, so in a half each player is nearly twice the size to it. Boxes are in
    /// Vision's coordinates for the whole frame.
    private static func halves(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, besides found: [CGRect],
                               problems: inout [String: Int]) -> [CGRect] {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let whole = upright.extent
        var added: [CGRect] = []
        for half in [CGRect(x: 0, y: 0, width: 0.56, height: 1), CGRect(x: 0.44, y: 0, width: 0.56, height: 1)] {
            let area = CGRect(x: whole.minX + half.minX * whole.width, y: whole.minY,
                              width: half.width * whole.width, height: whole.height)
            let part = upright.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
            let handler = VNImageRequestHandler(ciImage: part, options: [:])
            for box in RallyDetector.playerBodies(handler, minHeight: 0.03, maxMidY: 1, problems: &problems).map(\.box) {
                let full = CGRect(x: half.minX + box.minX * half.width, y: box.minY,
                                  width: box.width * half.width, height: box.height)
                guard !(found + added).contains(where: { sameBox($0, full) }) else { continue }
                added.append(full)
            }
        }
        return added
    }

    /// Two boxes on the same person: most of the smaller one is inside the other.
    private static func sameBox(_ a: CGRect, _ b: CGRect) -> Bool {
        let common = a.intersection(b)
        guard !common.isNull, common.width > 0, common.height > 0 else { return false }
        return common.width * common.height > 0.5 * min(a.width * a.height, b.width * b.height)
    }

    /// Writes what was found and followed to Cocut's logs folder (Following/<clip>.json), so a
    /// clip that's followed badly can be sent in and the following tuned on it.
    private static func record(url: URL, detections: Detections, anchors: [PlayerChain.Anchor], number: Int?,
                               path: [PlayerChain.Person?]) {
        func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Double] {
            ["x": round4(x), "y": round4(y), "w": round4(w), "h": round4(h)]
        }
        let frames = detections.frames
        let rectangles = detections.rectangles ?? []
        let json: [String: Any] = [
            "clip": url.lastPathComponent,
            "width": detections.width, "height": detections.height,
            "number": number as Any,
            "anchors": anchors.map { ["time": $0.time, "x": $0.x, "y": $0.y, "kind": $0.kind == .body ? "body" : "head"] },
            "frames": frames.indices.map { k -> [String: Any] in
                [
                    "time": round4(frames[k].time),
                    "people": frames[k].people.map { p -> [String: Any] in
                        var o: [String: Any] = box(p.x, p.y, p.width, p.height)
                        if let n = p.number { o["number"] = n }
                        return o
                    },
                    "rectangles": (k < rectangles.count ? rectangles[k] : []).map { box($0[0], $0[1], $0[2], $0[3]) },
                    "followed": path[k].map { box($0.x, $0.y, $0.width, $0.height) } as Any,
                ]
            },
        ]
        let folder = Platform.logsDirectory.appending(path: "Following", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: url.deletingPathExtension().lastPathComponent + ".json")
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: file, options: .atomic) }
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

    /// How to turn a track's stored frames upright, from its preferred transform.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0, t.b == 1, t.c == -1, t.d == 0 { return .right }
        if t.a == 0, t.b == -1, t.c == 1, t.d == 0 { return .left }
        if t.a == -1, t.b == 0, t.c == 0, t.d == -1 { return .down }
        return .up
    }
}

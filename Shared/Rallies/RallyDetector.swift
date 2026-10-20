import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import simd
import Vision

/// Finds rallies in a full volleyball match filmed from a fixed camera.
///
/// Two signals, both measured on the user's Mac:
/// - **The ball in the air.** Above the players, the picture is static walls and ceiling. During a
///   rally the ball keeps crossing that zone: a small, fast-moving object. Bursts of it mark play.
/// - **Referee whistles.** A steady tone near 3–4 kHz. Used to place the start (the serve whistle)
///   and end of each rally precisely; other courts' whistles alone never create a rally.
enum RallyDetector {
    struct Result: Codable, Sendable {
        var duration: Double
        /// Stretches where the ball was flying (seconds), before any lead-in or tail is added.
        var bursts: [Span]
        /// Times of detected whistles (seconds).
        var whistles: [Double]
        /// How far down the frame the "ball zone" reaches (fraction of the height).
        var ballZone: Double
        /// Jersey numbers read during the rallies: when, and which number.
        var numbers: [NumberRead] = []
        /// Nearby players seen once a second during the rallies, with how each one looks, so a
        /// player taught once can be found again (see `matches`).
        var people: [PersonSighting] = []
    }

    /// One player at one moment: where, an appearance fingerprint, and their number if it was read.
    struct PersonSighting: Codable, Sendable {
        var time: Double
        /// Unit coordinates, Vision's bottom-left origin.
        var box: CGRect
        /// Unit-length appearance features (Vision image feature print).
        var print: [Float]
        /// Jersey color (CIELAB, L/100, a/100, b/100), measured on the middle of the torso.
        var color: [Float] = []
        /// The number read on this player in this frame, if any.
        var number: Int?
        /// Which track (the same player followed through a rally) this is part of; -1 for none.
        var track: Int = -1
        /// The number read anywhere on this track: labels every frame of it.
        var trackNumber: Int?
    }

    struct NumberRead: Codable, Sendable, Hashable {
        var time: Double
        var number: Int
        /// Where in the picture it was read (unit coordinates, Vision's bottom-left origin).
        var x: Double = 0
        var y: Double = 0
    }

    struct Span: Codable, Sendable, Hashable {
        var start: Double
        var end: Double
    }

    enum DetectError: LocalizedError {
        case noVideo
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "This file has no video Cocut can read."
            case .unreadable(let why): return "The video couldn't be read. \(why)"
            }
        }
    }

    // Analysis frame: 320 px wide at 10 frames a second is plenty to see a ball against a wall.
    static let analysisWidth = 320
    static let analysisFPS: Int32 = 10

    /// Runs both passes. `progress` gets 0...1 (from the video pass, which takes longest).
    /// `courtArea` is the air above the user's court (unit coordinates, top-left origin): when set,
    /// the ball is only looked for there, which ignores neighboring courts, crowds and walkers.
    static func analyze(url: URL, courtArea: CGRect? = nil,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw DetectError.noVideo }
        let duration = try await asset.load(.duration).seconds
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        // The ball pass is most of the work (0–80%); reading jersey numbers is the rest.
        async let videoPart = videoPass(asset: asset, track: track, duration: duration, courtArea: courtArea) { progress($0 * 0.8) }
        async let audioPart = whistles(asset: asset, track: audioTrack)
        let (bursts, zone) = try await videoPart
        let whistles = await audioPart
        var result = Result(duration: duration, bursts: bursts, whistles: whistles, ballZone: zone)
        let spans = rallies(from: result, includeSetup: true)
        (result.numbers, result.people) = try await readNumbers(asset: asset, spans: spans) { progress(0.8 + $0 * 0.2) }
        Log.info("Rally analysis\(courtArea.map { " (court area \(Int($0.minX * 100))–\(Int($0.maxX * 100))% across, \(Int($0.minY * 100))–\(Int($0.maxY * 100))% down)" } ?? " (automatic area)"): \(bursts.count) ball bursts, \(whistles.count) whistles, ball zone \(Int(zone * 100))% of height, \(Int(duration))s")
        Log.info("Read \(result.numbers.count) jersey numbers in \(spans.count) rallies: \(readSummary(result.numbers))")
        Log.info("Saw \(result.people.count) nearby players (\(result.people.filter { $0.number != nil }.count) with a number read)")
        return result
    }

    // MARK: - Video: the ball above the players

    private static func videoPass(asset: AVURLAsset, track: AVAssetTrack, duration: Double, courtArea: CGRect?,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> ([Span], Double) {
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        let sw = abs(upright.width), sh = abs(upright.height)
        guard sw > 0, sh > 0 else { throw DetectError.noVideo }
        let w = analysisWidth
        var h = Int((Double(w) * sh / sw).rounded())
        h -= h % 2
        guard h >= 60 else { throw DetectError.unreadable("The picture is too narrow.") }

        // Let AVFoundation scale each frame down to the analysis size at 10 fps.
        let scale = CGFloat(w) / sw
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: w, height: h)
        composition.frameDuration = CMTime(value: 1, timescale: analysisFPS)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform
            .concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DetectError.unreadable("No video output.") }
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.unreadable(reader.error?.localizedDescription ?? "")
        }

        var finder = BallFinder(width: w, height: h, area: courtArea)
        var lastReport = -1.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            finder.add(luma: luma(of: buffer, width: w, height: h), time: time)
            if duration > 0, time - lastReport > 5 {
                lastReport = time
                progress(min(0.99, time / duration))
            }
        }
        if reader.status == .failed {
            throw DetectError.unreadable(reader.error?.localizedDescription ?? "")
        }
        progress(1)
        return finder.finish()
    }

    /// Rec. 601 luma from a BGRA frame.
    private static func luma(of buffer: CVPixelBuffer, width w: Int, height h: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var out = [UInt8](repeating: 0, count: w * h)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return out }
        let bw = min(w, CVPixelBufferGetWidth(buffer)), bh = min(h, CVPixelBufferGetHeight(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let px = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<bh {
            let row = px + y * stride
            for x in 0..<bw {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                out[y * w + x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
            }
        }
        return out
    }

    /// Small moving objects, frame by frame, plus how busy each row of the picture is.
    struct BallFinder {
        let w: Int, h: Int
        /// Rows searched for the ball; the real zone is decided at the end from row activity.
        let searchRows: Int
        static let threshold = 25        // luma change that counts as movement
        static let maxBlobArea = 45      // pixels, at 320 wide
        static let maxBlobSide = 10
        /// A ball moves at least this far between frames (pixels at 320 wide, 10 fps). A head of
        /// someone walking on the far side moves 1–2; a hit or passed ball moves 5–20.
        static let minStep: Float = 3
        /// The user's court area in analysis pixels, if they marked one.
        let area: CGRect?

        private var older: [UInt8]?
        private var previous: [UInt8]?
        private var times: [Double] = []
        /// Ball-like blobs per frame: (x, y) centers.
        private var detections: [[SIMD2<Float>]] = []
        private var rowActivity: [Double]
        private var activityFrames = 0

        init(width: Int, height: Int, area unit: CGRect? = nil) {
            w = width
            h = height
            if let unit {
                let r = CGRect(x: unit.minX * Double(width), y: unit.minY * Double(height),
                               width: unit.width * Double(width), height: unit.height * Double(height))
                area = r
                searchRows = max(1, min(height, Int(r.maxY.rounded(.up))))
            } else {
                area = nil
                searchRows = Int(Double(height) * 0.6)
            }
            rowActivity = [Double](repeating: 0, count: height)
        }

        mutating func add(luma c: [UInt8], time: Double) {
            defer {
                older = previous
                previous = c
                times.append(time)
            }
            guard let a = older, let b = previous else {
                detections.append([])
                return
            }
            // A pixel is "moving" when it differs from both of the last two frames.
            var mask = [UInt8](repeating: 0, count: w * h)
            let t = Self.threshold
            for y in 0..<h {
                var count = 0
                let row = y * w
                for x in 0..<w {
                    let i = row + x
                    let cv = Int(c[i])
                    if abs(cv - Int(b[i])) > t, abs(cv - Int(a[i])) > t {
                        mask[i] = 1
                        count += 1
                    }
                }
                rowActivity[y] += Double(count) / Double(w)
            }
            activityFrames += 1
            detections.append(blobs(in: &mask))
        }

        /// Centers of small connected blobs in the search rows (the mask is consumed).
        private func blobs(in mask: inout [UInt8]) -> [SIMD2<Float>] {
            var found: [SIMD2<Float>] = []
            var stack: [Int] = []
            for start in 0..<(searchRows * w) where mask[start] == 1 {
                mask[start] = 0
                stack.removeAll(keepingCapacity: true)
                stack.append(start)
                var area = 0, sx = 0, sy = 0
                var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
                while let i = stack.popLast() {
                    let x = i % w, y = i / w
                    area += 1; sx += x; sy += y
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    if area > 400 { continue } // big shape (a person): stop growing, it won't count anyway
                    for dy in -1...1 {
                        let ny = y + dy
                        guard ny >= 0, ny < searchRows else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            guard nx >= 0, nx < w else { continue }
                            let j = ny * w + nx
                            if mask[j] == 1 {
                                mask[j] = 0
                                stack.append(j)
                            }
                        }
                    }
                }
                if area >= 2, area <= Self.maxBlobArea,
                   maxX - minX + 1 <= Self.maxBlobSide, maxY - minY + 1 <= Self.maxBlobSide {
                    let center = SIMD2(Float(sx) / Float(area), Float(sy) / Float(area))
                    if let court = self.area, !court.contains(CGPoint(x: Double(center.x), y: Double(center.y))) { continue }
                    found.append(center)
                }
            }
            return found
        }

        /// Decides the ball zone, keeps blobs that move like a ball, and groups them into bursts.
        func finish() -> ([Span], Double) {
            let zoneRows = area.map { Int($0.maxY.rounded(.up)) } ?? ballZoneRows()
            let limit = Float(zoneRows)
            let n = detections.count
            // A frame "has the ball" when a blob in the zone continues one from the previous frame.
            var hit = [Double](repeating: 0, count: n)
            if n > 1 {
                for i in 1..<n {
                    let prev = detections[i - 1].filter { $0.y < limit }
                    guard !prev.isEmpty else { continue }
                    for p in detections[i] where p.y < limit {
                        if prev.contains(where: { let d = simd_distance($0, p); return d >= Self.minStep && d < 25 }) {
                            hit[i] = 1
                            break
                        }
                    }
                }
            }
            // Ball sightings per second, then stretches with at least two.
            let window = Int(RallyDetector.analysisFPS)
            var bursts: [Span] = []
            var runStart: Int?
            var sum = 0.0
            var activity = [Double](repeating: 0, count: n)
            for i in 0..<n {
                sum += hit[i]
                if i >= window { sum -= hit[i - window] }
                // Center the one-second window on the frame.
                let center = i - window / 2
                if center >= 0 { activity[center] = sum }
            }
            for i in 0...n {
                let on = i < n && activity[i] >= 2
                if on, runStart == nil { runStart = i }
                if !on, let s = runStart {
                    bursts.append(Span(start: time(at: s), end: time(at: i - 1)))
                    runStart = nil
                }
            }
            return (bursts, Double(zoneRows) / Double(h))
        }

        private func time(at i: Int) -> Double {
            guard !times.isEmpty else { return 0 }
            return times[max(0, min(times.count - 1, i))]
        }

        /// The static band at the top of the picture: from the top down to where the stands and
        /// players make rows busy. Falls back to 37% of the height.
        private func ballZoneRows() -> Int {
            guard activityFrames > 50 else { return Int(Double(h) * 0.37) }
            let rows = rowActivity.map { $0 / Double(activityFrames) }
            var smooth = rows
            for y in 1..<(h - 1) { smooth[y] = (rows[y - 1] + rows[y] + rows[y + 1]) / 3 }
            let top = Array(smooth[0..<max(1, h / 4)]).sorted()
            let baseline = top[top.count / 2]
            let threshold = max(4 * baseline, 0.0005)
            let from = h / 10
            let edge = (from..<h).first { smooth[$0] > threshold } ?? Int(Double(h) * 0.37)
            let lower = Int(Double(h) * 0.2), upper = Int(Double(h) * 0.6)
            return max(lower, min(upper, edge - 4))
        }
    }

    // MARK: - Jersey numbers

    /// Reads jersey numbers twice a second during each rally, with on-device text recognition.
    /// Players whose backs face the camera are read best; 1080p or better is recommended.
    private static func readNumbers(asset: AVURLAsset, spans: [Span],
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> ([NumberRead], [PersonSighting]) {
        var times: [Double] = []
        var spanOf: [Int] = []
        for (k, span) in spans.enumerated() {
            var t = span.start
            while t <= span.end {
                times.append(t)
                spanOf.append(k)
                t += 0.5
            }
        }
        guard !times.isEmpty else { return ([], []) }
        var tracker = Tracker()
        func makeGenerator() -> AVAssetImageGenerator {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2560, height: 2560)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            return generator
        }
        var generator = makeGenerator()

        var reads: [NumberRead] = []
        var people: [PersonSighting] = []
        var rejected: [String: Int] = [:]
        var problems: [String: Int] = [:]
        var unreadFrames = 0
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            if i % 20 == 0 { progress(Double(i) / Double(times.count)) }
            let at = CMTime(seconds: t, preferredTimescale: 600)
            var image: CGImage?
            do {
                image = try await generator.image(at: at).image
            } catch {
                // The decoder sometimes gives up partway through a long video (and then fails
                // every frame after). Start a fresh one and try again.
                problems["Frame: \(error.localizedDescription) (\((error as NSError).code))", default: 0] += 1
                try? await Task.sleep(for: .milliseconds(200))
                generator = makeGenerator()
                image = try? await generator.image(at: at).image
            }
            guard let image else {
                unreadFrames += 1
                continue
            }
            // Every frame: find the nearby players and how they look, and follow each one through
            // the rally. Once a second, also read each player's torso up close.
            var seen: Set<Int> = []
            let frame = numbers(in: image, closeUps: i % 2 == 0, wantPeople: true, rejected: &rejected, problems: &problems)
            for found in frame.reads where seen.insert(found.number).inserted {
                reads.append(NumberRead(time: t, number: found.number, x: found.x, y: found.y))
            }
            let first = people.count
            for person in frame.people {
                people.append(PersonSighting(time: t, box: person.box, print: person.print, color: person.color,
                                             number: person.number))
            }
            tracker.update(&people, from: first, time: t, span: spanOf[i])
        }
        progress(1)
        Log.info("Number pass: \(times.count) frames, \(unreadFrames) couldn't be read")
        if !problems.isEmpty {
            let list = problems.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) ×\($0.value)" }
            Log.error("Number pass problems: \(list.joined(separator: "; "))")
        }
        let common = rejected.sorted { $0.value > $1.value }.prefix(15).map { "\"\($0.key)\"×\($0.value)" }
        if !common.isEmpty { Log.info("Short text read but not taken as a number: \(common.joined(separator: ", "))") }
        let kept = dropStationary(reads)
        let keptNumbers = Set(kept.map(\.number))
        // A number dropped as a sign doesn't label anyone.
        for i in people.indices where people[i].number.map({ !keptNumbers.contains($0) }) ?? false {
            people[i].number = nil
        }
        let labeled = labelTracks(&people)
        let tracks = Set(people.map(\.track)).count
        Log.info("Followed \(people.count) player sightings as \(tracks) tracks; \(labeled) tracks have a number")
        return (kept, people)
    }

    /// Drops numbers that are nearly always read at the same spot: a sign, scoreboard or banner,
    /// not a player (players move around).
    static func dropStationary(_ reads: [NumberRead]) -> [NumberRead] {
        let byNumber = Dictionary(grouping: reads, by: \.number)
        var stationary: Set<Int> = []
        for (number, list) in byNumber where list.count >= 6 {
            let xs = list.map(\.x).sorted(), ys = list.map(\.y).sorted()
            let mx = xs[xs.count / 2], my = ys[ys.count / 2]
            let near = list.filter { abs($0.x - mx) < 0.02 && abs($0.y - my) < 0.02 }.count
            if Double(near) / Double(list.count) > 0.8 { stationary.insert(number) }
        }
        if !stationary.isEmpty { Log.info("Ignoring numbers that never move (signs?): \(stationary.sorted())") }
        return reads.filter { !stationary.contains($0.number) }
    }

    /// One- or two-digit numbers in the lower part of the picture (where the near team is), with
    /// where each was read. Short text that isn't a number is counted in `rejected` for the log.
    typealias FrameNumbers = (reads: [(number: Int, x: Double, y: Double)],
                              people: [(box: CGRect, print: [Float], color: [Float], number: Int?)])

    static func numbers(in image: CGImage, closeUps: Bool = false, wantPeople: Bool = false,
                        rejected: inout [String: Int], problems: inout [String: Int]) -> FrameNumbers {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // The whole lower part of the picture (Vision's origin is bottom-left: the lower 65%).
        var found = recognize(image, handler, in: CGRect(x: 0, y: 0, width: 1, height: 0.65),
                              minimumTextHeight: 0.012, level: .accurate, rejected: &rejected, problems: &problems)
        guard closeUps || wantPeople else { return (found, []) }

        // The nearby players (big enough for a readable number).
        let bodies = playerBodies(handler, minHeight: 0.10, maxMidY: 0.8, problems: &problems)
        var people: [(box: CGRect, print: [Float], color: [Float], number: Int?)] = []
        let fullFrame = found
        for body in bodies {
            var reads: [(number: Int, x: Double, y: Double)] = []
            // Close-ups: read each player's torso on its own. Text recognition finds a lone "1"
            // or "11" far more readily when it fills the region it's given.
            if closeUps, body.torso.width * Double(image.width) >= 40, body.torso.height * Double(image.height) >= 40 {
                reads = recognize(image, handler, in: body.torso, minimumTextHeight: 0.012, level: .accurate,
                                  rejected: &rejected, problems: &problems)
                if reads.isEmpty {
                    // The fast recognizer works character by character and catches a lone "1"
                    // the accurate one sometimes skips.
                    reads = recognize(image, handler, in: body.torso, minimumTextHeight: 0.012, level: .fast,
                                      rejected: &rejected, problems: &problems)
                }
                for read in reads where !found.contains(where: { $0.number == read.number }) {
                    found.append(read)
                }
            }
            guard wantPeople else { continue }
            // This player's number: read on their torso, or read in the whole frame right there.
            let zone = body.torso.insetBy(dx: -0.01, dy: -0.01)
            let onThem = Set(reads.map(\.number) + fullFrame.filter { zone.contains(CGPoint(x: $0.x, y: $0.y)) }.map(\.number))
            if let print = featurePrint(handler, region: body.box) ?? featurePrint(of: image, region: body.box) {
                people.append((body.box, print, jerseyColor(image, torso: body.torso), onThem.count == 1 ? onThem.first : nil))
            }
        }
        return (found, people)
    }

    /// Players in the frame (unit coordinates, bottom-left origin): the whole body and the torso
    /// (shoulders to hips, where the number is). Body-pose detection finds several people at once
    /// and gives their joints; human rectangles add anyone it missed.
    static func playerBodies(_ handler: VNImageRequestHandler, minHeight: CGFloat, maxMidY: CGFloat,
                             problems: inout [String: Int]) -> [(box: CGRect, torso: CGRect)] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        func torsoGuess(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX - box.width * 0.15, y: box.minY + box.height * 0.42,
                   width: box.width * 1.3, height: box.height * 0.48).intersection(unit)
        }
        var out: [(box: CGRect, torso: CGRect)] = []

        let pose = VNDetectHumanBodyPoseRequest()
        do {
            try handler.perform([pose])
        } catch {
            problems["Pose: \(error.localizedDescription)", default: 0] += 1
        }
        for observation in pose.results ?? [] {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            let good = points.values.filter { $0.confidence > 0.2 }
            guard good.count >= 6 else { continue }
            let xs = good.map(\.location.x), ys = good.map(\.location.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            // Joints stop at the ankles and eyes: pad for the feet, the top of the head and arms.
            let w = maxX - minX, h = maxY - minY
            let box = CGRect(x: minX - w * 0.15, y: minY - h * 0.06, width: w * 1.3, height: h * 1.16).intersection(unit)
            let joints: [VNHumanBodyPoseObservation.JointName] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
            let core = joints.compactMap { points[$0] }.filter { $0.confidence > 0.2 }.map(\.location)
            var torso = torsoGuess(box)
            if core.count >= 3, let cx0 = core.map(\.x).min(), let cx1 = core.map(\.x).max(),
               let cy0 = core.map(\.y).min(), let cy1 = core.map(\.y).max() {
                // A side-on player's shoulders and hips are close together: keep it a sensible width.
                let tw = max(cx1 - cx0, box.width * 0.4), th = max(cy1 - cy0, box.height * 0.25)
                let mid = (cx0 + cx1) / 2
                torso = CGRect(x: mid - tw * 0.75, y: cy0 - th * 0.1, width: tw * 1.5, height: th * 1.25).intersection(unit)
            }
            out.append((box, torso))
        }

        let rectangles = VNDetectHumanRectanglesRequest()
        rectangles.upperBodyOnly = false
        do {
            try handler.perform([rectangles])
        } catch {
            problems["People: \(error.localizedDescription)", default: 0] += 1
        }
        for box in (rectangles.results ?? []).map(\.boundingBox)
        where !out.contains(where: { overlap($0.box, box) > 0.3 }) && !looksLikeGroup(box) {
            out.append((box, torsoGuess(box)))
        }
        return Array(out
            .filter { $0.box.height >= minHeight && $0.box.midY < maxMidY }
            .sorted { $0.box.height > $1.box.height }
            .prefix(10))
    }

    /// Wider than one standing or crouching person (in a 16:9 frame): the rectangle detector
    /// sometimes boxes a whole cluster of people.
    static func looksLikeGroup(_ box: CGRect) -> Bool {
        box.height > 0 && box.width * 16 / 9 / box.height > 0.9
    }

    /// Intersection over union of two boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }

    // MARK: - Tracking

    /// Follows players from frame to frame within a rally, by where they are and how they look.
    struct Tracker {
        private struct Active { var id: Int; var box: CGRect; var print: [Float]; var time: Double }
        private var active: [Active] = []
        private var span = -1
        private var nextID = 0

        /// Assigns `people[from...]` (one frame's players at `time`) to tracks.
        mutating func update(_ people: inout [PersonSighting], from first: Int, time: Double, span: Int) {
            if span != self.span {
                active = []
                self.span = span
            }
            active.removeAll { time - $0.time > 1.6 }
            var pairs: [(score: Float, person: Int, track: Int)] = []
            for p in first..<people.count {
                let person = people[p]
                for (a, track) in active.enumerated() {
                    let dt = max(0.5, time - track.time)
                    let dx = person.box.midX - track.box.midX, dy = person.box.midY - track.box.midY
                    let distance = Double((dx * dx + dy * dy).squareRoot())
                    // A player moves at most a few meters in half a second.
                    guard distance < min(0.3, 0.12 * dt / 0.5) else { continue }
                    let ratio = person.box.height / max(track.box.height, 0.001)
                    guard ratio > 0.6, ratio < 1.6 else { continue }
                    let similarity = RallyDetector.dot(person.print, track.print)
                    guard similarity >= 0.5 else { continue }
                    pairs.append((similarity - Float(distance) * 2, p, a))
                }
            }
            var usedPeople: Set<Int> = [], usedTracks: Set<Int> = []
            for pair in pairs.sorted(by: { $0.score > $1.score })
            where !usedPeople.contains(pair.person) && !usedTracks.contains(pair.track) {
                usedPeople.insert(pair.person)
                usedTracks.insert(pair.track)
                people[pair.person].track = active[pair.track].id
                active[pair.track].box = people[pair.person].box
                active[pair.track].print = people[pair.person].print
                active[pair.track].time = time
            }
            for p in first..<people.count where !usedPeople.contains(p) {
                people[p].track = nextID
                active.append(Active(id: nextID, box: people[p].box, print: people[p].print, time: time))
                nextID += 1
            }
        }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Gives each track the number read on it (when one number clearly wins), so a number read
    /// once labels the player for the whole stretch they were followed. Returns how many tracks
    /// got a number.
    @discardableResult
    static func labelTracks(_ people: inout [PersonSighting]) -> Int {
        var votes: [Int: [Int: Int]] = [:]
        for p in people where p.track >= 0 {
            if let n = p.number { votes[p.track, default: [:]][n, default: 0] += 1 }
        }
        var label: [Int: Int] = [:]
        for (track, counts) in votes {
            let sorted = counts.sorted { $0.value > $1.value }
            let second = sorted.count > 1 ? sorted[1].value : 0
            if let top = sorted.first, top.value >= 1, top.value >= 2 * second { label[track] = top.key }
        }
        for i in people.indices { people[i].trackNumber = label[people[i].track] }
        return label.count
    }

    /// Numbers of players followed in a rally: a track with a number, seen at least twice in it.
    static func trackPlayers(in span: Span, people: [PersonSighting], allowed: Set<Int>) -> Set<Int> {
        var counts: [Int: Int] = [:]
        for p in people where p.time >= span.start && p.time <= span.end {
            if let n = p.trackNumber { counts[n, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value >= 2 && (allowed.isEmpty || allowed.contains($0.key)) }.keys)
    }

    // MARK: - Jersey color

    /// The average color of the middle of the torso (unit, bottom-left origin), in CIELAB scaled
    /// to about -1...1: tells a libero's jersey, the other team and the referees apart.
    static func jerseyColor(_ image: CGImage, torso: CGRect) -> [Float] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // The middle half of the torso, away from arms and background.
        let core = torso.insetBy(dx: torso.width * 0.25, dy: torso.height * 0.25)
        let pixels = CGRect(x: core.minX * w, y: (1 - core.maxY) * h, width: core.width * w, height: core.height * h).integral
        guard pixels.width >= 2, pixels.height >= 2, let crop = image.cropping(to: pixels),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 24, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 6, height: 6))
        guard let data = ctx.data else { return [] }
        let px = data.assumingMemoryBound(to: UInt8.self)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<36 {
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2])
        }
        return lab(r / 36 / 255, g / 36 / 255, b / 36 / 255)
    }

    /// sRGB (0...1) to CIELAB (D65), scaled: L/100, a/100, b/100.
    static func lab(_ r: Double, _ g: Double, _ b: Double) -> [Float] {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = (0.4124 * rl + 0.3576 * gl + 0.1805 * bl) / 0.95047
        let y = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
        let z = (0.0193 * rl + 0.1192 * gl + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let L = 116 * f(y) - 16, A = 500 * (f(x) - f(y)), B = 200 * (f(y) - f(z))
        return [Float(L / 100), Float(A / 100), Float(B / 100)]
    }

    /// How strongly jersey color counts next to the rest of the appearance.
    static let colorWeight: Float = 1.5

    /// Appearance plus jersey color, as one unit-length vector for comparing players. With no
    /// color (a player remembered from another match, whose uniform may differ) the color part is
    /// zero, so it neither helps nor hurts any match.
    static func features(_ print: [Float], color: [Float]?) -> [Float] {
        var v = print
        if let color, color.count == 3 {
            v.append(contentsOf: color.map { $0 * colorWeight })
        } else {
            v.append(contentsOf: [0, 0, 0])
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    // MARK: - Appearance (teach a player)

    /// An appearance fingerprint of `region` (unit coordinates, bottom-left origin), unit length:
    /// from the person re-identification model, which is trained to tell people apart (build,
    /// hair, shoes, knee pads) rather than just describe a picture. Apple's general image
    /// fingerprint is the fallback if the model can't be loaded.
    static func featurePrint(_ handler: VNImageRequestHandler, region: CGRect) -> [Float]? {
        if let model = ReIDModel.shared {
            return ReIDModel.embedding(handler, region: region, model: model)
        }
        let request = VNGenerateImageFeaturePrintRequest()
        request.regionOfInterest = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        request.imageCropAndScaleOption = .scaleFit
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return nil }
        let values: [Float]
        switch observation.elementType {
        case .float:
            values = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            values = observation.data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
        default:
            return nil
        }
        var norm: Float = 0
        vDSP_svesq(values, 1, &norm, vDSP_Length(values.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        var scale = 1 / norm
        var unit = [Float](repeating: 0, count: values.count)
        vDSP_vsmul(values, 1, &scale, &unit, 1, vDSP_Length(values.count))
        return unit
    }

    /// Everyone big enough to click on in a frame, with their appearance (for teaching a player).
    /// Also returns a line for the log saying what was found or what went wrong.
    static func people(in image: CGImage) -> (people: [(box: CGRect, print: [Float], color: [Float])], note: String) {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var problems: [String: Int] = [:]
        let bodies = playerBodies(handler, minHeight: 0.06, maxMidY: 1, problems: &problems)
        var out: [(box: CGRect, print: [Float], color: [Float])] = []
        for body in bodies {
            if let print = featurePrint(handler, region: body.box) ?? featurePrint(of: image, region: body.box) {
                out.append((body.box, print, jerseyColor(image, torso: body.torso)))
            }
        }
        var note = "\(bodies.count) people found, \(out.count) with appearance, frame \(image.width)×\(image.height)"
        if !problems.isEmpty { note += "; " + problems.map { "\($0.key) ×\($0.value)" }.joined(separator: "; ") }
        return (out, note)
    }

    /// The appearance of `region` (unit, bottom-left origin) from a cropped copy of the image:
    /// a fallback when asking for a region of the whole frame fails.
    static func featurePrint(of image: CGImage, region: CGRect) -> [Float]? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixels = CGRect(x: region.minX * w, y: (1 - region.maxY) * h,
                            width: region.width * w, height: region.height * h).integral
        guard let crop = image.cropping(to: pixels) else { return nil }
        return featurePrint(VNImageRequestHandler(cgImage: crop, options: [:]),
                            region: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Who a followed player (a track) is, and how sure Cocut is.
    struct TrackDecision: Sendable, Hashable {
        enum Source: Sendable, Hashable {
            /// The user said who this is.
            case taught
            /// Their number was read.
            case read
            /// They look clearly like a known player.
            case matched
            /// Not sure: worth asking the user.
            case uncertain
            /// A number was read, but they look like someone else: worth checking.
            case conflict
        }
        var track: Int
        /// Who it is, when decided: a jersey number, or `otherTeam` for opponents and referees.
        var number: Int?
        var source: Source
        /// Who they look most like, and how much (average similarity over the track).
        var guess: Int?
        var score: Float
        /// How far ahead of the next-closest player the guess is.
        var margin: Float
        /// Frames in the track.
        var count: Int
        /// Usually boxed as a cluster of people rather than one player: never asked about.
        var isGroup = false
    }

    /// The label for "not our team" (opponents, referees, coaches).
    static let otherTeam = -1

    /// Decides who every followed player is. Tracks taught by the user keep that; tracks with a
    /// read number keep it; every other track goes to the known player (taught, read or "other
    /// team") most of its frames look like (see `agreement`). Examples per player: what was taught
    /// plus up to 60 frames of their labeled tracks, spread across the match.
    /// Each frame votes for the players of its `neighbors` closest examples; a track is decided
    /// when at least `agreement` of its votes go to one player. Votes don't depend on how the
    /// appearance features happen to scale, unlike a similarity threshold.
    static func decide(people: [PersonSighting], taught: [Int: [[Float]]], taughtTracks: [Int: Int],
                       agreement: Float, neighbors: Int = 7) -> [Int: TrackDecision] {
        guard let printDims = people.first?.print.count, printDims > 0 else { return [:] }
        let dims = printDims + 3
        let vectors = people.map { features($0.print, color: $0.color) }
        func label(of p: PersonSighting) -> Int? { taughtTracks[p.track] ?? p.trackNumber }

        var labels: [Int] = []
        var examples: [Float] = []
        func add(_ print: [Float], _ label: Int) {
            guard print.count == dims else { return }
            labels.append(label)
            examples.append(contentsOf: print)
        }
        for (number, prints) in taught { prints.forEach { add($0, number) } }
        let labeled = people.indices.filter { label(of: people[$0]) != nil && !looksLikeGroup(people[$0].box) }
        let known = Dictionary(grouping: labeled, by: { label(of: people[$0])! })
        for (number, list) in known where list.count >= 5 || taught[number] != nil {
            let step = max(1, list.count / 60)
            for i in stride(from: 0, to: list.count, by: step).prefix(60) { add(vectors[list[i]], number) }
        }

        let tracks = Dictionary(grouping: people.indices, by: { people[$0].track })
        var out: [Int: TrackDecision] = [:]
        let distinct = Array(Set(labels)).sorted()
        let u = distinct.count, l = labels.count
        guard l > 0 else {
            for (track, members) in tracks {
                out[track] = TrackDecision(track: track, number: label(of: people[members[0]]), source: .uncertain,
                                           guess: nil, score: 0, margin: 0, count: members.count)
            }
            return out
        }
        let column = Dictionary(uniqueKeysWithValues: distinct.enumerated().map { ($1, $0) })
        var transposed = [Float](repeating: 0, count: dims * l)
        vDSP_mtrans(examples, 1, &transposed, 1, vDSP_Length(dims), vDSP_Length(l))

        // Each sighting's best similarity to each player, and its nearest examples' votes.
        var best = [Float](repeating: -1, count: people.count * u)
        var votes = [Float](repeating: 0, count: people.count * u)
        let k = min(neighbors, l)
        let chunk = 2048
        var start = 0
        while start < people.count {
            let rows = min(chunk, people.count - start)
            var block = [Float](repeating: 0, count: rows * dims)
            for r in 0..<rows where vectors[start + r].count == dims {
                block.replaceSubrange(r * dims..<(r + 1) * dims, with: vectors[start + r])
            }
            var sims = [Float](repeating: 0, count: rows * l)
            vDSP_mmul(block, 1, transposed, 1, &sims, 1, vDSP_Length(rows), vDSP_Length(l), vDSP_Length(dims))
            var topSims = [Float](repeating: -2, count: k)
            var topCols = [Int](repeating: 0, count: k)
            for r in 0..<rows {
                let base = (start + r) * u
                for i in 0..<k { topSims[i] = -2 }
                for c in 0..<l {
                    let sim = sims[r * l + c]
                    let slot = base + column[labels[c]]!
                    if sim > best[slot] { best[slot] = sim }
                    // Keep the k closest examples (insertion into a short sorted list).
                    if sim > topSims[k - 1] {
                        var i = k - 1
                        while i > 0 && topSims[i - 1] < sim {
                            topSims[i] = topSims[i - 1]
                            topCols[i] = topCols[i - 1]
                            i -= 1
                        }
                        topSims[i] = sim
                        topCols[i] = c
                    }
                }
                for i in 0..<k where topSims[i] > -2 { votes[base + column[labels[topCols[i]]]!] += 1 }
            }
            start += rows
        }

        for (track, members) in tracks {
            var mean = [Float](repeating: 0, count: u)
            var share = [Float](repeating: 0, count: u)
            for m in members {
                for c in 0..<u {
                    mean[c] += best[m * u + c]
                    share[c] += votes[m * u + c]
                }
            }
            let total = max(1, share.reduce(0, +))
            for c in 0..<u {
                mean[c] /= Float(members.count)
                share[c] /= total
            }
            let order = share.indices.sorted { share[$0] > share[$1] }
            let top = order[0]
            let guess = distinct[top]
            let margin = share[top] - (order.count > 1 ? share[order[1]] : 0)
            let widths = members.filter { looksLikeGroup(people[$0].box) }.count
            var decision = TrackDecision(track: track, number: nil, source: .uncertain, guess: guess,
                                         score: share[top], margin: margin, count: members.count,
                                         isGroup: widths * 2 > members.count)
            if let taughtAs = taughtTracks[track] {
                decision.number = taughtAs
                decision.source = .taught
            } else if let read = people[members[0]].trackNumber {
                decision.number = read
                decision.source = .read
                // Read as one number but clearly looks like someone else: maybe a misread.
                if guess != read, members.count >= 3, share[top] >= 0.6,
                   (column[read].map { share[$0] } ?? 0) < 0.2 {
                    decision.source = .conflict
                }
            } else if !decision.isGroup, share[top] >= agreement + (members.count < 3 ? 0.1 : 0),
                      mean[top] >= 0.3 {
                decision.number = guess
                decision.source = .matched
            }
            out[track] = decision
        }
        return out
    }

    /// Numbers of players decided in a rally (seen in at least two frames of it), leaving out the
    /// other team and numbers not `allowed` (when given).
    static func decidedPlayers(in span: Span, people: [PersonSighting], decisions: [Int: TrackDecision],
                               allowed: Set<Int>) -> Set<Int> {
        var counts: [Int: Int] = [:]
        for p in people where p.time >= span.start && p.time <= span.end {
            if let n = decisions[p.track]?.number ?? p.trackNumber, n >= 0 { counts[n, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value >= 2 && (allowed.isEmpty || allowed.contains($0.key)) }.keys)
    }

    /// One- or two-digit numbers in `region` (unit coordinates, bottom-left origin), with where
    /// each was read in the whole picture.
    private static func recognize(_ image: CGImage, _ handler: VNImageRequestHandler, in region: CGRect, minimumTextHeight: Float,
                                  level: VNRequestTextRecognitionLevel, rejected: inout [String: Int],
                                  problems: inout [String: Int]) -> [(number: Int, x: Double, y: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.regionOfInterest = region
        request.minimumTextHeight = minimumTextHeight
        do {
            try handler.perform([request])
        } catch {
            // Text recognition sometimes fails when the Mac is busy; try once more, fresh. Log
            // which reader and roughly how big the region was, to see what fails.
            let w = Int(region.width * CGFloat(image.width)) / 50 * 50
            let h = Int(region.height * CGFloat(image.height)) / 50 * 50
            problems["Text (\(level == .fast ? "fast" : "accurate"), ~\(w)×\(h) px): \(error.localizedDescription)", default: 0] += 1
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                problems["Text: recovered on retry", default: 0] += 1
            } catch {
                return []
            }
        }
        var found: [(Int, Double, Double)] = []
        for observation in request.results ?? [] {
            // Boxes are relative to the region; place them in the whole picture.
            let box = observation.boundingBox
            let x = region.minX + box.midX * region.width
            let y = region.minY + box.midY * region.height
            var taken = false
            for candidate in observation.topCandidates(3) where candidate.confidence >= 0.3 {
                if let n = jerseyNumber(from: candidate.string) {
                    found.append((n, Double(x), Double(y)))
                    taken = true
                    break
                }
            }
            if !taken, let best = observation.topCandidates(1).first?.string, best.count <= 3 {
                rejected[best, default: 0] += 1
            }
        }
        return found
    }

    /// Text recognition reads a jersey's "1" as I, l or | about as often as as a digit (and "11"
    /// as "II" or "ll"), since it's looking for words. Short readings are mapped back to digits.
    static func jerseyNumber(from raw: String) -> Int? {
        // Drop punctuation the reader adds around a number ("26:", "26.", "$26", "#12").
        let text = raw.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters
                .union(.symbols).union(.whitespacesAndNewlines).subtracting(CharacterSet(charactersIn: "|!][/\\")))
        guard (1...2).contains(text.count) else { return nil }
        let lookalikes: [Character: Character] = [
            // In a slanted jersey font a "1" is a single diagonal stroke: "/" or "\\".
            "I": "1", "l": "1", "|": "1", "i": "1", "!": "1", "]": "1", "[": "1", "j": "1", "J": "1", "/": "1", "\\": "1",
            "O": "0", "o": "0", "D": "0", "Q": "0",
            "Z": "2", "z": "2", "S": "5", "s": "5", "B": "8", "G": "6", "b": "6", "g": "9", "q": "9",
        ]
        let digits = String(text.map { lookalikes[$0] ?? $0 })
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let n = Int(digits) else { return nil }
        // A two-letter word that maps to digits ("SO", "IO") is too risky unless it's the 1/11 case.
        let letters = text.filter { !$0.isNumber }
        // Unless it starts with a 1 look-alike: "Is" is 15, "IZ" is 12, "II" is 11.
        if text.count == 2, letters.count == 2, let lead = text.first, !"Il|i!/\\".contains(lead) { return nil }
        return n
    }

    /// Numbers that appear in a rally. A number counts when it's read at least twice in the
    /// rally, or once if it turns up all through the match (some numbers, like a lone 1, are
    /// read only now and then). With a roster, only roster numbers count; without one, only
    /// numbers seen across several rallies (drops referees and passers-by).
    static func players(in span: Span, reads: [NumberRead], roster: Set<Int>, frequent: Set<Int>) -> [Int] {
        var counts: [Int: Int] = [:]
        for r in reads where r.time >= span.start && r.time <= span.end {
            counts[r.number, default: 0] += 1
        }
        let allowed = roster.isEmpty ? frequent : roster
        let established = establishedNumbers(reads: reads)
        return counts.filter { number, count in
            allowed.contains(number) && (count >= 2 || established.contains(number))
        }.keys.sorted()
    }

    /// Numbers read twice or more in at least two rallies, or at least once in four or more.
    static func frequentNumbers(spans: [Span], reads: [NumberRead]) -> Set<Int> {
        var strong: [Int: Int] = [:], any: [Int: Int] = [:]
        for span in spans {
            var counts: [Int: Int] = [:]
            for r in reads where r.time >= span.start && r.time <= span.end { counts[r.number, default: 0] += 1 }
            for (n, c) in counts {
                any[n, default: 0] += 1
                if c >= 2 { strong[n, default: 0] += 1 }
            }
        }
        return Set(strong.filter { $0.value >= 2 }.keys).union(any.filter { $0.value >= 4 }.keys)
    }

    /// Numbers read at least 8 times over the match, at moments spread across it (not one burst).
    static func establishedNumbers(reads: [NumberRead]) -> Set<Int> {
        var out: Set<Int> = []
        for (number, list) in Dictionary(grouping: reads, by: \.number) where list.count >= 8 {
            // At least four separate moments, a minute or more apart.
            var moments = 0, last = -Double.infinity
            for t in list.map(\.time).sorted() where t - last >= 60 {
                moments += 1
                last = t
            }
            if moments >= 4 { out.insert(number) }
        }
        return out
    }

    /// A line for the log: how often each number was read.
    static func readSummary(_ reads: [NumberRead]) -> String {
        Dictionary(grouping: reads, by: \.number)
            .map { (number: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(30)
            .map { "#\($0.number)×\($0.count)" }
            .joined(separator: " ")
    }

    // MARK: - Audio: referee whistles

    static let sampleRate = 16_000.0
    private static let fftSize = 1024
    private static let hop = 800 // 50 ms

    /// Whistle times, or none when there's no sound (or it can't be read).
    private static func whistles(asset: AVURLAsset, track: AVAssetTrack?) async -> [Double] {
        guard let track else { return [] }
        do {
            return try await whistlePass(asset: asset, track: track)
        } catch {
            Log.error("Whistle pass failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func whistlePass(asset: AVURLAsset, track: AVAssetTrack) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var tracker = WhistleTracker()
        var pending: [Float] = []
        var offset = 0           // read position in `pending`
        var frameIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            pending.append(contentsOf: chunk)
            while pending.count - offset >= fftSize {
                let tonal = tracker.analyzer.measure(pending, from: offset)
                let time = (Double(frameIndex * hop) + Double(fftSize) / 2) / sampleRate
                tracker.add(tonal: tonal.prominence, peakHz: tonal.peakHz, time: time)
                offset += hop
                frameIndex += 1
            }
            // Drop consumed samples now and then.
            if offset > 160_000 {
                pending.removeFirst(offset)
                offset = 0
            }
        }
        return tracker.finish()
    }

    /// One FFT frame: how much one tone stands out in the whistle band.
    final class ToneAnalyzer {
        private let setup: FFTSetup
        private let log2n = vDSP_Length(10)
        private var window = [Float](repeating: 0, count: 1024)
        private var input = [Float](repeating: 0, count: 1024)
        private var real = [Float](repeating: 0, count: 512)
        private var imag = [Float](repeating: 0, count: 512)
        private var power = [Float](repeating: 0, count: 512)
        // 2.0–4.8 kHz at 15.625 Hz per bin.
        private let lowBin = 128, highBin = 307

        init() {
            setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
            vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM))
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func measure(_ samples: [Float], from offset: Int) -> (prominence: Double, peakHz: Double) {
            samples.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + offset, 1, window, 1, &input, 1, 1024)
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    input.withUnsafeBufferPointer { inp in
                        inp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 512) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, 512)
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, 512)
                }
            }
            let band = Array(power[lowBin...highBin])
            var peak: Float = 0
            var peakIndex = 0
            for (i, v) in band.enumerated() where v > peak {
                peak = v
                peakIndex = i
            }
            let median = band.sorted()[band.count / 2] + 1e-12
            let prominence = 10 * log10(Double(peak + 1e-12) / Double(median))
            return (prominence, Double(lowBin + peakIndex) * RallyDetector.sampleRate / 1024)
        }
    }

    /// Whistles: the tone stands out by 29 dB or more for at least 0.2 s, at a steady pitch.
    struct WhistleTracker {
        let analyzer = ToneAnalyzer()
        private var runStart: Double?
        private var runPitches: [Double] = []
        private var events: [Double] = []

        mutating func add(tonal: Double, peakHz: Double, time: Double) {
            if tonal > 29 {
                if runStart == nil { runStart = time }
                runPitches.append(peakHz)
            } else {
                close()
            }
        }

        private mutating func close() {
            if let start = runStart, runPitches.count >= 4 {
                let mean = runPitches.reduce(0, +) / Double(runPitches.count)
                let variance = runPitches.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(runPitches.count)
                if variance.squareRoot() < 150 { events.append(start) }
            }
            runStart = nil
            runPitches.removeAll()
        }

        mutating func finish() -> [Double] {
            close()
            return events
        }
    }

    // MARK: - Rallies from the signals

    /// Rallies that are really timeouts: the team huddles to one side, so the players seen sit far
    /// off where they usually are during play, and fewer of them are seen. Judged against this
    /// match's own typical rally, so it doesn't depend on which side the bench is. On one match
    /// this caught 8 of 9 timeouts and no real rallies. Returns indices into `spans`.
    static func breaks(in spans: [Span], people: [PersonSighting]) -> Set<Int> {
        let sorted = people.sorted { $0.time < $1.time }
        var medians: [Double?] = []
        var rates: [Double] = []
        for span in spans {
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid].time < span.start { lo = mid + 1 } else { hi = mid } }
            var xs: [Double] = []
            var i = lo
            while i < sorted.count && sorted[i].time <= span.end { xs.append(Double(sorted[i].box.midX)); i += 1 }
            // Too few sightings to judge.
            guard xs.count >= 20 else { medians.append(nil); rates.append(0); continue }
            xs.sort()
            medians.append(xs[xs.count / 2])
            rates.append(Double(xs.count) / max(0.1, span.end - span.start))
        }
        let judged = spans.indices.filter { medians[$0] != nil }
        guard judged.count >= 10 else { return [] }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        let typicalX = median(judged.map { medians[$0]! })
        let typicalRate = median(judged.map { rates[$0] })
        return Set(judged.filter { abs(medians[$0]! - typicalX) > 0.15 && rates[$0] < 0.85 * typicalRate })
    }

    /// Turns bursts and whistles into rallies.
    /// - `includeSetup`: start at the serve whistle (shows the server getting ready); otherwise
    ///   start just before the ball first goes up.
    static func rallies(from result: Result, includeSetup: Bool) -> [Span] {
        // Join bursts split by a low pass or dig; drop blips (a stray ball, a warm-up toss).
        var merged: [Span] = []
        for b in result.bursts {
            // A whistle in the gap means the rally ended there (the ball going back to the
            // server isn't part of it).
            let whistleInGap = merged.last.map { last in
                b.start - last.end >= 1.5 && result.whistles.contains { $0 > last.end && $0 < b.start }
            } ?? false
            if var last = merged.last, b.start - last.end < 3.5, !whistleInGap {
                last.end = b.end
                merged[merged.count - 1] = last
            } else {
                merged.append(b)
            }
        }
        merged = merged.filter { $0.end - $0.start >= 1.5 }

        var out: [Span] = []
        for b in merged {
            var start: Double
            if includeSetup {
                // The serve whistle, but never more than 5 seconds of setup: in a busy hall the
                // nearest whistle before the serve is often another court's.
                let serve = result.whistles.last { $0 >= b.start - 8 && $0 <= b.start }
                start = max(serve.map { $0 - 0.5 } ?? b.start - 3, b.start - 5)
            } else {
                start = b.start - 1.5
            }
            let whistle = result.whistles.first { $0 >= b.end && $0 <= b.end + 3 }
            var end = whistle.map { $0 + 0.5 } ?? b.end + 1.5
            start = max(0, start)
            end = min(result.duration, end)
            if let last = out.last, start <= last.end {
                out[out.count - 1].end = max(last.end, end)
            } else if end - start > 1 {
                out.append(Span(start: start, end: end))
            }
        }
        return out
    }
}

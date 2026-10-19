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
        result.numbers = try await readNumbers(asset: asset, spans: spans) { progress(0.8 + $0 * 0.2) }
        Log.info("Rally analysis\(courtArea.map { " (court area \(Int($0.minX * 100))–\(Int($0.maxX * 100))% across, \(Int($0.minY * 100))–\(Int($0.maxY * 100))% down)" } ?? " (automatic area)"): \(bursts.count) ball bursts, \(whistles.count) whistles, ball zone \(Int(zone * 100))% of height, \(Int(duration))s")
        Log.info("Read \(result.numbers.count) jersey numbers in \(spans.count) rallies: \(readSummary(result.numbers))")
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
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> [NumberRead] {
        var times: [Double] = []
        for span in spans {
            var t = span.start
            while t <= span.end {
                times.append(t)
                t += 0.5
            }
        }
        guard !times.isEmpty else { return [] }
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
            // Once a second, also look closely at each nearby player's torso.
            var seen: Set<Int> = []
            for found in numbers(in: image, closeUps: i % 2 == 0, rejected: &rejected, problems: &problems)
            where seen.insert(found.number).inserted {
                reads.append(NumberRead(time: t, number: found.number, x: found.x, y: found.y))
            }
        }
        progress(1)
        Log.info("Number pass: \(times.count) frames, \(unreadFrames) couldn't be read")
        if !problems.isEmpty {
            let list = problems.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ×\($0.value)" }
            Log.error("Number pass problems: \(list.joined(separator: "; "))")
        }
        let common = rejected.sorted { $0.value > $1.value }.prefix(15).map { "\"\($0.key)\"×\($0.value)" }
        if !common.isEmpty { Log.info("Short text read but not taken as a number: \(common.joined(separator: ", "))") }
        return dropStationary(reads)
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
    static func numbers(in image: CGImage, closeUps: Bool = false, rejected: inout [String: Int],
                        problems: inout [String: Int]) -> [(number: Int, x: Double, y: Double)] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // The whole lower part of the picture (Vision's origin is bottom-left: the lower 65%).
        var found = recognize(handler, in: CGRect(x: 0, y: 0, width: 1, height: 0.65),
                              minimumTextHeight: 0.012, level: .accurate, rejected: &rejected, problems: &problems)
        guard closeUps else { return found }

        // Close-ups: find the people, then read each nearby player's torso on its own. Text
        // recognition finds a lone "1" or "11" far more readily when it fills the region it's
        // given than as a sliver in a whole gym.
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        do {
            try handler.perform([people])
        } catch {
            problems["People: \(error.localizedDescription)", default: 0] += 1
        }
        let bodies = (people.results ?? [])
            .map(\.boundingBox)
            .filter { $0.height >= 0.12 && $0.midY < 0.75 } // near enough for a readable number
            .sorted { $0.height > $1.height }
            .prefix(8)
        let already = Set(found.map(\.number))
        for body in bodies {
            // From the hips to the shoulders, a little wider than the body.
            let torso = CGRect(x: body.minX - body.width * 0.15, y: body.minY + body.height * 0.42,
                               width: body.width * 1.3, height: body.height * 0.48)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            // Too small to hold a readable number (and text recognition errors on tiny regions).
            guard torso.width * Double(image.width) >= 40, torso.height * Double(image.height) >= 40 else { continue }
            var reads = recognize(handler, in: torso, minimumTextHeight: 0.012, level: .accurate, rejected: &rejected, problems: &problems)
            if reads.isEmpty {
                // The fast recognizer works character by character and catches a lone "1" the
                // accurate one sometimes skips.
                reads = recognize(handler, in: torso, minimumTextHeight: 0.012, level: .fast, rejected: &rejected, problems: &problems)
            }
            for read in reads where !already.contains(read.number) {
                found.append(read)
            }
        }
        return found
    }

    /// One- or two-digit numbers in `region` (unit coordinates, bottom-left origin), with where
    /// each was read in the whole picture.
    private static func recognize(_ handler: VNImageRequestHandler, in region: CGRect, minimumTextHeight: Float,
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
            problems["Text: \(error.localizedDescription)", default: 0] += 1
            return []
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
        if text.count == 2, letters.count == 2, !letters.allSatisfy({ "Il|i!/\\".contains($0) }) { return nil }
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

import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import simd

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
    static func analyze(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw DetectError.noVideo }
        let duration = try await asset.load(.duration).seconds
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        async let videoPart = videoPass(asset: asset, track: track, duration: duration, progress: progress)
        async let audioPart = whistles(asset: asset, track: audioTrack)
        let (bursts, zone) = try await videoPart
        let whistles = await audioPart
        Log.info("Rally analysis: \(bursts.count) ball bursts, \(whistles.count) whistles, ball zone \(Int(zone * 100))% of height, \(Int(duration))s")
        return Result(duration: duration, bursts: bursts, whistles: whistles, ballZone: zone)
    }

    // MARK: - Video: the ball above the players

    private static func videoPass(asset: AVURLAsset, track: AVAssetTrack, duration: Double,
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

        var finder = BallFinder(width: w, height: h)
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

        private var older: [UInt8]?
        private var previous: [UInt8]?
        private var times: [Double] = []
        /// Ball-like blobs per frame: (x, y) centers.
        private var detections: [[SIMD2<Float>]] = []
        private var rowActivity: [Double]
        private var activityFrames = 0

        init(width: Int, height: Int) {
            w = width
            h = height
            searchRows = Int(Double(height) * 0.6)
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
                    found.append(SIMD2(Float(sx) / Float(area), Float(sy) / Float(area)))
                }
            }
            return found
        }

        /// Decides the ball zone, keeps blobs that move like a ball, and groups them into bursts.
        func finish() -> ([Span], Double) {
            let zoneRows = ballZoneRows()
            let limit = Float(zoneRows)
            let n = detections.count
            // A frame "has the ball" when a blob in the zone continues one from the previous frame.
            var hit = [Double](repeating: 0, count: n)
            if n > 1 {
                for i in 1..<n {
                    let prev = detections[i - 1].filter { $0.y < limit }
                    guard !prev.isEmpty else { continue }
                    for p in detections[i] where p.y < limit {
                        if prev.contains(where: { let d = simd_distance($0, p); return d > 1.5 && d < 25 }) {
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
            if var last = merged.last, b.start - last.end < 3.5 {
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
                let serve = result.whistles.last { $0 >= b.start - 9 && $0 <= b.start }
                start = serve.map { $0 - 0.5 } ?? b.start - 3
            } else {
                start = b.start - 1.5
            }
            let whistle = result.whistles.first { $0 >= b.end && $0 <= b.end + 4 }
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

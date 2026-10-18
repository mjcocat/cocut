import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import SwiftUI

enum ReelTransition: String, Codable, CaseIterable, Identifiable {
    case cut, crossfade
    var id: String { rawValue }
    var title: String { self == .cut ? "Cut" : "Crossfade" }
}

enum ReelResolution: String, Codable, CaseIterable, Identifiable {
    case hd720, hd1080, uhd4k
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        }
    }
    var size: CGSize {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        }
    }
}

struct ExportOptions: Codable, Equatable {
    var includeIntro = true
    var cardSeconds: Double = 5
    var transition: ReelTransition = .crossfade
    var showClipNames = false
    var includeSound = true
    var resolution: ReelResolution = .hd1080
    var frameRate = 30
    /// Crop away black bars around the picture (e.g. a 16:9 video recorded full screen on a 16:10 display).
    var removeBlackBars = true
    /// Scale clips to cover the whole frame, cropping edges, instead of fitting inside it.
    var fillFrame = false

    static let transitionSeconds = 0.6

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportOptions()
        includeIntro = (try? c.decodeIfPresent(Bool.self, forKey: .includeIntro)) ?? d.includeIntro
        cardSeconds = (try? c.decodeIfPresent(Double.self, forKey: .cardSeconds)) ?? d.cardSeconds
        transition = (try? c.decodeIfPresent(ReelTransition.self, forKey: .transition)) ?? d.transition
        showClipNames = (try? c.decodeIfPresent(Bool.self, forKey: .showClipNames)) ?? d.showClipNames
        includeSound = (try? c.decodeIfPresent(Bool.self, forKey: .includeSound)) ?? d.includeSound
        resolution = (try? c.decodeIfPresent(ReelResolution.self, forKey: .resolution)) ?? d.resolution
        frameRate = (try? c.decodeIfPresent(Int.self, forKey: .frameRate)) ?? d.frameRate
        removeBlackBars = (try? c.decodeIfPresent(Bool.self, forKey: .removeBlackBars)) ?? d.removeBlackBars
        fillFrame = (try? c.decodeIfPresent(Bool.self, forKey: .fillFrame)) ?? d.fillFrame
    }
}

enum ExportError: LocalizedError {
    case noClips
    case unreadable(String)
    case cardFailed
    case sessionUnavailable
    case composition(String)

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips in the reel. Record or import some first."
        case .unreadable(let name): return "“\(name)” couldn't be read. It may have been moved or deleted."
        case .cardFailed: return "The player card couldn't be drawn."
        case .sessionUnavailable: return "macOS couldn't start the export."
        case .composition(let reason): return "The reel couldn't be assembled. \(reason)"
        }
    }
}

/// One piece of the reel: a clip (or a rendered card) and the part of it to use.
struct ReelSegment: Sendable {
    let url: URL
    let start: Double
    let duration: Double
    let title: String?
    let isCard: Bool
}

/// Builds the highlight reel: intro card, clips in order (trimmed), end card, with optional
/// crossfades, clip-name captions and sound, then exports an MP4.
@MainActor
@Observable
final class ReelExporter {
    enum State: Equatable {
        case idle
        case preparing(String)
        case exporting(Double)
        case finished(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    var options: ExportOptions {
        didSet { saveOptions() }
    }

    var isRunning: Bool {
        switch state {
        case .preparing, .exporting: return true
        default: return false
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    private static let optionsKey = "exportOptions"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let decoded = try? JSONDecoder().decode(ExportOptions.self, from: data) {
            options = decoded
        } else {
            options = ExportOptions()
        }
    }

    var exportsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies")
        let dir = movies.appending(path: "Cocut/Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Estimated running time of the finished reel.
    func estimatedDuration(clips: [Clip], profile: PlayerProfile) -> Double {
        var pieces = clips.map(\.effectiveDuration)
        if options.includeIntro { pieces.insert(options.cardSeconds, at: 0) }
        if profile.showEndCard { pieces.append(options.cardSeconds) }
        let total = pieces.reduce(0, +)
        guard options.transition == .crossfade, pieces.count > 1 else { return total }
        return total - Double(pieces.count - 1) * ExportOptions.transitionSeconds
    }

    func reset() {
        if !isRunning { state = .idle }
    }

    func cancel() {
        task?.cancel()
    }

    func export(clips: [Clip], library: ClipLibrary, profile: PlayerProfile, headshot: NSImage?, to output: URL) {
        guard !isRunning else { return }
        let options = self.options
        task = Task {
            do {
                try await run(clips: clips, library: library, profile: profile, headshot: headshot,
                              options: options, output: output)
                state = .finished(output)
                Log.info("Exported reel to \(output.path(percentEncoded: false))")
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                state = .idle
                Log.info("Export cancelled")
            } catch {
                Log.error("Export failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    // MARK: Pipeline

    private func run(clips: [Clip], library: ClipLibrary, profile: PlayerProfile, headshot: NSImage?,
                     options: ExportOptions, output: URL) async throws {
        guard !clips.isEmpty else { throw ExportError.noClips }
        let renderSize = options.resolution.size
        let fps = Int32(options.frameRate)
        let work = FileManager.default.temporaryDirectory.appending(path: "CocutExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Cards → short movies.
        var segments: [ReelSegment] = []
        if options.includeIntro {
            state = .preparing("Drawing the intro card…")
            segments.append(try await cardSegment(kind: .intro, profile: profile, headshot: headshot,
                                                  size: renderSize, fps: fps, seconds: options.cardSeconds, work: work))
        }
        for clip in clips {
            let url = library.url(for: clip)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw ExportError.unreadable(clip.title)
            }
            let duration = clip.trimEndSeconds - clip.trimStartSeconds
            guard duration > 0.1 else { continue }
            segments.append(ReelSegment(url: url, start: clip.trimStartSeconds, duration: duration,
                                        title: clip.title, isCard: false))
        }
        if profile.showEndCard {
            state = .preparing("Drawing the end card…")
            segments.append(try await cardSegment(kind: .end, profile: profile, headshot: headshot,
                                                  size: renderSize, fps: fps, seconds: options.cardSeconds, work: work))
        }
        try Task.checkCancellation()

        // 2. Assemble.
        state = .preparing("Assembling \(clips.count) clips…")
        let accent = NSColor(profile.accent.color).cgColor
        let built = try await ReelComposer.build(segments: segments, options: options,
                                                 renderSize: renderSize, accent: accent)
        try Task.checkCancellation()

        // 3. Export.
        state = .exporting(0)
        guard let session = AVAssetExportSession(asset: built.composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionUnavailable
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)

        let progress = Task { [weak self] in
            for await exportState in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = exportState {
                    self?.state = .exporting(p.fractionCompleted)
                }
            }
        }
        defer { progress.cancel() }
        try await session.export(to: output, as: .mp4)
    }

    private func cardSegment(kind: CardKind, profile: PlayerProfile, headshot: NSImage?,
                             size: CGSize, fps: Int32, seconds: Double, work: URL) async throws -> ReelSegment {
        guard let image = PlayerCardView.render(profile: profile, headshot: headshot, kind: kind, pixelSize: size) else {
            throw ExportError.cardFailed
        }
        let url = work.appending(path: kind == .intro ? "intro.mov" : "end.mov")
        try await Task.detached(priority: .userInitiated) {
            try CardMovieWriter.write(image, size: size, seconds: seconds, fps: fps,
                                      fadeIn: kind == .intro, fadeOut: kind == .end, to: url)
        }.value
        return ReelSegment(url: url, start: 0, duration: seconds, title: nil, isCard: true)
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Self.optionsKey)
        }
    }
}

// MARK: - Composition

enum ReelComposer {
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix?
    }

    private struct Loaded {
        /// Held on purpose: an AVAssetTrack only weakly references its asset, and inserting a
        /// track whose asset has been freed fails with -11800 / -12780.
        let asset: AVURLAsset
        let segment: ReelSegment
        /// The exact range to take from the source, clamped to the video track.
        let source: CMTimeRange
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let audioRange: CMTimeRange?
        let transform: CGAffineTransform
        /// Part of the source picture to show (natural coordinates), when black bars were found.
        let crop: CGRect?
    }

    static func build(segments: [ReelSegment], options: ExportOptions,
                      renderSize: CGSize, accent: CGColor) async throws -> Built {
        let timescale: CMTimeScale = 600
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

        // Load every source.
        var loaded: [Loaded] = []
        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.unreadable(segment.title ?? segment.url.lastPathComponent)
            }
            var audio: AVAssetTrack?
            if !segment.isCard, options.includeSound {
                audio = try await asset.loadTracks(withMediaType: .audio).first
            }
            let natural = try await video.load(.naturalSize)
            let preferred = try await video.load(.preferredTransform)
            let videoRange = try await video.load(.timeRange)
            var audioRange: CMTimeRange?
            if let audio { audioRange = try await audio.load(.timeRange) }

            // Clamp the requested range to what the video track really holds. Tracks inside one
            // file can differ slightly in length (sound starts with the first frame), and asking
            // for time a track doesn't have makes the whole insert fail.
            let wantedStart = time(segment.start)
            let wantedEnd = time(segment.start + segment.duration)
            let start = CMTimeMaximum(wantedStart, videoRange.start)
            let end = CMTimeMinimum(wantedEnd, videoRange.end)
            guard end > start, (end - start).seconds > 0.05 else {
                Log.error("Skipping \(segment.url.lastPathComponent): no usable video in range")
                continue
            }
            let source = CMTimeRange(start: start, end: end)
            let fixed = ReelSegment(url: segment.url, start: start.seconds, duration: source.duration.seconds,
                                    title: segment.title, isCard: segment.isCard)
            var crop: CGRect?
            if !segment.isCard, options.removeBlackBars, preferred.isIdentity {
                crop = await contentRect(asset: asset, natural: natural, range: source)
                if let crop {
                    Log.info("\(segment.url.lastPathComponent): cropping black bars to \(Int(crop.width))x\(Int(crop.height)) of \(Int(natural.width))x\(Int(natural.height))")
                }
            }
            let transform: CGAffineTransform
            if let crop {
                transform = place(crop, into: renderSize, fill: options.fillFrame && !segment.isCard)
            } else if preferred.isIdentity {
                transform = place(CGRect(origin: .zero, size: natural), into: renderSize,
                                  fill: options.fillFrame && !segment.isCard)
            } else {
                transform = aspectFit(natural: natural, preferred: preferred, into: renderSize)
            }
            loaded.append(Loaded(asset: asset, segment: fixed, source: source, video: video, audio: audio, audioRange: audioRange,
                                 transform: transform, crop: crop))
        }
        guard !loaded.isEmpty else { throw ExportError.noClips }

        let composition = AVMutableComposition()
        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.composition("No video tracks.")
        }
        let videoTracks = [videoA, videoB]
        var audioTracks: [AVMutableCompositionTrack] = []
        if loaded.contains(where: { $0.audio != nil }),
           let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let b = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            audioTracks = [a, b]
        }

        // Overlap between neighbors (0 for cuts), never more than a third of either piece.
        let n = loaded.count
        var overlaps: [Double] = Array(repeating: 0, count: max(0, n - 1))
        if options.transition == .crossfade {
            for i in 0..<(n - 1) {
                overlaps[i] = min(ExportOptions.transitionSeconds,
                                  loaded[i].segment.duration / 3, loaded[i + 1].segment.duration / 3)
            }
        }

        // Lay pieces on alternating tracks so crossfades can overlap.
        var starts: [Double] = []
        var cursor = 0.0
        for (i, item) in loaded.enumerated() {
            starts.append(cursor)
            let source = item.source
            do {
                try videoTracks[i % 2].insertTimeRange(source, of: item.video, at: time(cursor))
            } catch {
                let ns = error as NSError
                Log.error("Video insert failed for \(item.segment.url.lastPathComponent) range \(source.start.seconds)+\(source.duration.seconds): \(ns.domain) \(ns.code) \(ns.userInfo)")
                throw ExportError.composition("“\(item.segment.title ?? item.segment.url.lastPathComponent)” couldn't be added (\(ns.code)).")
            }
            // Sound is best-effort: take only the part the audio track actually covers.
            if let audio = item.audio, let audioRange = item.audioRange, !audioTracks.isEmpty {
                let overlap = source.intersection(audioRange)
                if !overlap.isEmpty, overlap.duration.seconds > 0.05 {
                    let offset = overlap.start - source.start
                    do {
                        try audioTracks[i % 2].insertTimeRange(overlap, of: audio, at: time(cursor) + offset)
                    } catch {
                        let ns = error as NSError
                        Log.error("Audio insert failed for \(item.segment.url.lastPathComponent): \(ns.domain) \(ns.code); continuing without its sound")
                    }
                }
            }
            cursor += item.segment.duration - (i < n - 1 ? overlaps[i] : 0)
        }
        let total = cursor

        // Video instructions: a solo stretch for each piece, then a blend into the next.
        var instructions: [AVMutableVideoCompositionInstruction] = []
        func layer(_ i: Int, at start: Double) -> AVMutableVideoCompositionLayerInstruction {
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[i % 2])
            li.setTransform(loaded[i].transform, at: time(start))
            if let crop = loaded[i].crop {
                li.setCropRectangle(crop, at: time(start))
            }
            return li
        }
        func instruction(_ from: Double, _ to: Double, _ layers: [AVMutableVideoCompositionLayerInstruction]) {
            guard to - from > 0.0005 else { return }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: time(from), end: time(to))
            ins.layerInstructions = layers
            ins.backgroundColor = CGColor(gray: 0, alpha: 1)
            instructions.append(ins)
        }
        for i in 0..<n {
            let soloStart = starts[i] + (i > 0 ? overlaps[i - 1] : 0)
            let soloEnd = starts[i] + loaded[i].segment.duration - (i < n - 1 ? overlaps[i] : 0)
            instruction(soloStart, soloEnd, [layer(i, at: soloStart)])
            if i < n - 1, overlaps[i] > 0 {
                let from = soloEnd, to = soloEnd + overlaps[i]
                let outgoing = layer(i, at: from)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                                        timeRange: CMTimeRange(start: time(from), end: time(to)))
                instruction(from, to, [outgoing, layer(i + 1, at: from)])
            }
        }
        guard !instructions.isEmpty else { throw ExportError.composition("Nothing to show.") }
        // Make the instructions tile the timeline exactly (rounding to the 1/600s grid can leave slivers).
        for k in instructions.indices.dropFirst() {
            let prevEnd = instructions[k - 1].timeRange.end
            let cur = instructions[k].timeRange
            instructions[k].timeRange = CMTimeRange(start: prevEnd, end: cur.end)
        }
        if let first = instructions.first {
            first.timeRange = CMTimeRange(start: .zero, end: first.timeRange.end)
        }
        if let last = instructions.last {
            last.timeRange = CMTimeRange(start: last.timeRange.start, end: composition.duration)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        videoComposition.instructions = instructions

        if options.showClipNames {
            videoComposition.animationTool = captionTool(loaded: loaded, starts: starts, overlaps: overlaps,
                                                         renderSize: renderSize, accent: accent)
        }

        // Audio: duck each clip out/in across crossfades.
        var audioMix: AVMutableAudioMix?
        if audioTracks.count == 2 {
            let params = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
            for i in 0..<(n - 1) where overlaps[i] > 0 {
                let from = starts[i] + loaded[i].segment.duration - overlaps[i]
                let range = CMTimeRange(start: time(from), duration: time(overlaps[i]))
                params[i % 2].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
                params[(i + 1) % 2].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range)
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = params
            audioMix = mix
        }

        Log.info("Composed reel: \(n) pieces, \(String(format: "%.1f", total))s at \(Int(renderSize.width))x\(Int(renderSize.height))")
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    /// Scales a source to fit the frame (letterboxed), honoring its rotation.
    /// Maps `rect` of an upright source onto the frame: fit (letterbox) or fill (crop overflow), centered.
    static func place(_ rect: CGRect, into render: CGSize, fill: Bool) -> CGAffineTransform {
        guard rect.width > 0, rect.height > 0 else { return .identity }
        let sx = render.width / rect.width, sy = render.height / rect.height
        let s = fill ? max(sx, sy) : min(sx, sy)
        return CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (render.width - rect.width * s) / 2,
                                             y: (render.height - rect.height * s) / 2))
    }

    /// Finds the picture inside black bars by sampling a few frames. Returns nil when there's
    /// nothing worth cropping.
    static func contentRect(asset: AVURLAsset, natural: CGSize, range: CMTimeRange) async -> CGRect? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)

        var found: CGRect?
        for fraction in [0.2, 0.5, 0.8] {
            let t = range.start + CMTimeMultiplyByFloat64(range.duration, multiplier: fraction)
            guard let image = try? await generator.image(at: t).image,
                  let rect = brightBounds(of: image) else { continue }
            let scaleX = natural.width / CGFloat(image.width)
            let scaleY = natural.height / CGFloat(image.height)
            let mapped = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                                width: rect.width * scaleX, height: rect.height * scaleY)
            found = found.map { $0.union(mapped) } ?? mapped
        }
        guard var rect = found else { return nil }
        // Pull in a hair to avoid a dark seam, then snap to even pixels.
        rect = rect.insetBy(dx: 2, dy: 2).integral
        rect.origin.x -= rect.origin.x.truncatingRemainder(dividingBy: 2)
        rect.origin.y -= rect.origin.y.truncatingRemainder(dividingBy: 2)
        let area = natural.width * natural.height
        let kept = rect.width * rect.height / area
        // Nearly the whole frame: nothing to crop. Tiny: probably a dark scene, don't trust it.
        guard kept < 0.96, kept > 0.15 else { return nil }
        return rect
    }

    /// Bounding box (top-left origin) of rows/columns that have meaningful non-black content.
    private static func brightBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 8, h > 8,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.assumingMemoryBound(to: UInt8.self)
        let threshold: UInt8 = 28
        var rowHas = [Bool](repeating: false, count: h)
        var colCount = [Int](repeating: 0, count: w)
        for y in 0..<h {
            var count = 0
            let row = px + y * w
            for x in 0..<w where row[x] > threshold {
                count += 1
                colCount[x] += 1
            }
            rowHas[y] = count > w / 50
        }
        guard let top = rowHas.firstIndex(of: true), let bottom = rowHas.lastIndex(of: true),
              let left = colCount.firstIndex(where: { $0 > h / 50 }),
              let right = colCount.lastIndex(where: { $0 > h / 50 }),
              bottom > top, right > left else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    static func aspectFit(natural: CGSize, preferred: CGAffineTransform, into render: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let w = abs(rect.width), h = abs(rect.height)
        guard w > 0, h > 0 else { return .identity }
        let s = min(render.width / w, render.height / h)
        return preferred
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (render.width - w * s) / 2, y: (render.height - h * s) / 2))
    }

    /// Lower-third captions with each clip's name, faded in and out near the start of the clip.
    private static func captionTool(loaded: [Loaded], starts: [Double], overlaps: [Double],
                                    renderSize: CGSize, accent: CGColor) -> AVVideoCompositionCoreAnimationTool {
        let scale = renderSize.height / 1080
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        for (i, item) in loaded.enumerated() where !item.segment.isCard {
            guard let title = item.segment.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { continue }
            let visibleStart = starts[i] + (i > 0 ? overlaps[i - 1] : 0) + 0.3
            let visibleFor = min(3.0, max(1.0, item.segment.duration - 0.8))

            let font = NSFont.systemFont(ofSize: 40 * scale, weight: .bold)
            let textSize = (title as NSString).size(withAttributes: [.font: font])
            let padX = 28 * scale, barW = 8 * scale
            let height = 76 * scale
            let width = min(renderSize.width * 0.8, textSize.width + padX * 2 + barW)

            let box = CALayer()
            box.frame = CGRect(x: 60 * scale, y: 70 * scale, width: width, height: height)
            box.backgroundColor = CGColor(gray: 0, alpha: 0.62)
            box.cornerRadius = 14 * scale
            box.masksToBounds = true
            box.opacity = 0

            let bar = CALayer()
            bar.frame = CGRect(x: 0, y: 0, width: barW, height: height)
            bar.backgroundColor = accent
            box.addSublayer(bar)

            let text = CATextLayer()
            text.string = title
            text.font = font
            text.fontSize = 40 * scale
            text.foregroundColor = CGColor(gray: 1, alpha: 1)
            text.alignmentMode = .left
            text.truncationMode = .end
            text.contentsScale = 2
            text.frame = CGRect(x: barW + padX, y: (height - textSize.height) / 2 - 2 * scale,
                                width: width - barW - padX * 2, height: textSize.height + 4 * scale)
            box.addSublayer(text)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.12, 0.85, 1]
            fade.beginTime = AVCoreAnimationBeginTimeAtZero + visibleStart
            fade.duration = visibleFor
            fade.isRemovedOnCompletion = false
            fade.fillMode = .both
            box.add(fade, forKey: "fade")

            parent.addSublayer(box)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}

// MARK: - Card movies

/// Turns a still card into a short H.264 movie, with an optional fade from or to black.
enum CardMovieWriter {
    static func write(_ image: CGImage, size: CGSize, seconds: Double, fps: Int32,
                      fadeIn: Bool, fadeOut: Bool, to url: URL) throws {
        let width = Int(size.width), height = Int(size.height)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw ExportError.cardFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.cardFailed }
        writer.startSession(atSourceTime: .zero)

        let total = max(1, Int(seconds * Double(fps)))
        let fadeFrames = max(1, Int(0.5 * Double(fps)))
        var full: CVPixelBuffer?

        for i in 0..<total {
            try Task.checkCancellation()
            var alpha: CGFloat = 1
            if fadeIn, i < fadeFrames { alpha = CGFloat(i + 1) / CGFloat(fadeFrames) }
            if fadeOut, i >= total - fadeFrames { alpha = min(alpha, CGFloat(total - i) / CGFloat(fadeFrames)) }

            let buffer: CVPixelBuffer
            if alpha >= 1 {
                if full == nil { full = makeBuffer(image, width: width, height: height, alpha: 1) }
                guard let full else { throw ExportError.cardFailed }
                buffer = full
            } else {
                guard let faded = makeBuffer(image, width: width, height: height, alpha: alpha) else {
                    throw ExportError.cardFailed
                }
                buffer = faded
            }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else {
                throw ExportError.cardFailed
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw ExportError.cardFailed }
    }

    private static func makeBuffer(_ image: CGImage, width: Int, height: Int, alpha: CGFloat) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(alpha)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

import AVFoundation
import CoreMedia
import CoreText
import QuartzCore
import SwiftUI

enum ReelTransition: String, Codable, CaseIterable, Identifiable {
    case cut, crossfade
    var id: String { rawValue }
    var title: String { self == .cut ? "Cut" : "Crossfade" }
}

/// The spotlight's outline.
enum SpotlightShape: String, Codable, CaseIterable, Identifiable {
    case oval, circle
    var id: String { rawValue }
    var title: String { self == .oval ? "Oval" : "Circle" }
    /// Width of the outline relative to its height (an upright oval fits a standing player).
    var aspect: CGFloat { self == .oval ? 0.6 : 1 }
}

/// How the spotlight's ring is drawn: none (just the lit area around the athlete), a thin,
/// standard or thick line, or a hand-painted brush stroke.
enum SpotlightRing: String, Codable, CaseIterable, Identifiable {
    case none, thin, standard, thick, painted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "No Ring"
        case .thin: return "Thin"
        case .standard: return "Standard"
        case .thick: return "Thick"
        case .painted: return "Painted"
        }
    }
    /// How much of a painted ring is painted `t` seconds into the spotlight: over 0.9 s, easing
    /// out like a hand finishing a stroke.
    static func brushProgress(_ t: Double) -> Double {
        let p = min(1, max(0, (t - 0.1) / 0.9))
        return 1 - (1 - p) * (1 - p)
    }

    /// Line width at 1080p (a painted stroke's widest point).
    var width: CGFloat {
        switch self {
        case .none: return 0
        case .thin: return 4
        case .standard: return 8
        case .thick: return 16
        case .painted: return 24
        }
    }

    /// The painted ring around the ellipse at `center` (radii `rx`, `ry`), as filled shapes with
    /// their opacity: one calligraphy brush stroke on a smooth oval (thick and thin with the
    /// brush's angle), that stops a little short of where it began and breaks into dry-brush
    /// streaks. `progress` (0...1) is how much has been painted. `yUp`: Core Graphics coordinates
    /// (the same stroke, mirrored so it looks alike either way up).
    static func paintedStrokes(center: CGPoint, rx: CGFloat, ry: CGFloat, width: CGFloat, progress: Double = 1,
                               yUp: Bool = false) -> [(path: CGPath, alpha: CGFloat)] {
        let a0 = -0.62 * Double.pi, sweep = 1.9 * Double.pi
        func point(_ u: Double) -> CGPoint {
            let a = a0 + sweep * u, k = CGFloat(1 + 0.035 * u)
            return CGPoint(x: center.x + rx * k * CGFloat(cos(a)), y: center.y + ry * k * CGFloat(sin(a)))
        }
        func tangent(_ u: Double) -> (x: CGFloat, y: CGFloat) {
            let p = point(max(0, u - 0.002)), q = point(min(1, u + 0.002))
            let dx = q.x - p.x, dy = q.y - p.y, length = max(0.0001, (dx * dx + dy * dy).squareRoot())
            return (dx / length, dy / length)
        }
        // A broad brush held at 45°: thickest moving across it, thinnest along it.
        func nib(_ u: Double) -> CGFloat {
            let t = tangent(u)
            return width * CGFloat(0.3 + 0.7 * abs(sin(atan2(Double(t.y), Double(t.x)) - .pi / 4)))
        }
        func body(_ u: Double) -> CGFloat {
            var w = nib(u)
            if u < 0.04 { w *= CGFloat(0.55 + 0.45 * u / 0.04) }
            if u > 0.84 { w *= CGFloat(max(0, (0.97 - u) / 0.13)) }
            return w
        }
        func ribbon(_ us: [Double], width: (Double) -> CGFloat, offset: (Double) -> CGFloat = { _ in 0 }) -> CGPath {
            var left: [CGPoint] = [], right: [CGPoint] = []
            for u in us {
                let p = point(u), t = tangent(u), n = (x: -t.y, y: t.x)
                let o = offset(u), w = width(u) / 2
                let c = CGPoint(x: p.x + n.x * o, y: p.y + n.y * o)
                left.append(CGPoint(x: c.x + n.x * w, y: c.y + n.y * w))
                right.append(CGPoint(x: c.x - n.x * w, y: c.y - n.y * w))
            }
            let path = CGMutablePath()
            let outline = (left + right.reversed()).map { yUp ? CGPoint(x: $0.x, y: 2 * center.y - $0.y) : $0 }
            path.addLines(between: outline)
            path.closeSubpath()
            return path
        }
        var out: [(path: CGPath, alpha: CGFloat)] = []
        let steps = 240
        let end = min(progress, 0.97)
        let shown = Int(end * Double(steps))
        if shown >= 1 { out.append((ribbon((0...shown).map { Double($0) / Double(steps) }, width: body), 1)) }
        // Dry-brush streaks where the stroke runs out.
        let seeds = [0.13, 0.71, 0.42, 0.95, 0.27, 0.58, 0.84]
        let begin = 0.78
        for (j, seed) in seeds.enumerated() {
            let offset = (Double(j) / Double(seeds.count - 1) - 0.5) * 0.9
            let stop = 0.93 + 0.07 * seed
            let e = min(progress, stop)
            guard e > begin else { continue }
            let us = (0...40).map { begin + (e - begin) * Double($0) / 40 }
            out.append((ribbon(us, width: { u in width * 0.2 * CGFloat(max(0.2, 1 - (u - begin) / (stop - begin))) },
                               offset: { u in CGFloat(offset) * nib(u) }), 0.85))
        }
        return out
    }
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
    /// Freeze on the first frame and ring the athlete, for clips with a spotlight.
    var showSpotlights = true
    var spotlightShape: SpotlightShape = .oval
    var spotlightRing: SpotlightRing = .none
    /// The ring's color as "#RRGGBB"; nil uses the team color.
    var spotlightColor: String? = nil
    /// A bar along the bottom of the intro card that fills while it's on screen.
    var introProgressBar = true
    /// Widescreen, or phone-shaped for social apps.
    var shape: ReelShape = .widescreen
    /// Phone shapes: follow the spotlighted player through each clip.
    var followSpotlight = true
    /// Phone shapes: clips without a spotlight (or not followed) are centered, or shown whole.
    var unspotlitFraming: PhoneFraming = .centered
    /// The Cocut logo, faint, in a corner of the clips, and "Made with Cocut" at the
    /// bottom of the end card.
    var madeWithCocut = true

    /// The size to draw at: phone shapes are 1080 wide; previews are two-thirds size.
    func renderSize(preview: Bool = false) -> CGSize {
        let size = shape.isPhone ? shape.phoneSize : (preview ? ReelResolution.hd720.size : resolution.size)
        guard preview, shape.isPhone else { return size }
        return CGSize(width: size.width * 2 / 3, height: (size.height * 2 / 3).rounded())
    }

    /// Spotlight stills are drawn widescreen; in a phone reel the frame looks at the athlete.
    /// (Cards have tall layouts of their own and are drawn at the reel's size.)
    func stillSize(for renderSize: CGSize) -> CGSize {
        guard shape.isPhone else { return renderSize }
        let width = renderSize.width * 16 / 9
        return CGSize(width: (width / 2).rounded() * 2, height: renderSize.width)
    }

    static let transitionSeconds = 0.6
    /// How long a spotlight holds the first frame.
    static let spotlightSeconds = 1.4

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
        showSpotlights = (try? c.decodeIfPresent(Bool.self, forKey: .showSpotlights)) ?? d.showSpotlights
        spotlightShape = (try? c.decodeIfPresent(SpotlightShape.self, forKey: .spotlightShape)) ?? d.spotlightShape
        spotlightRing = (try? c.decodeIfPresent(SpotlightRing.self, forKey: .spotlightRing)) ?? d.spotlightRing
        spotlightColor = try? c.decodeIfPresent(String.self, forKey: .spotlightColor)
        introProgressBar = (try? c.decodeIfPresent(Bool.self, forKey: .introProgressBar)) ?? d.introProgressBar
        shape = (try? c.decodeIfPresent(ReelShape.self, forKey: .shape)) ?? d.shape
        followSpotlight = (try? c.decodeIfPresent(Bool.self, forKey: .followSpotlight)) ?? d.followSpotlight
        unspotlitFraming = (try? c.decodeIfPresent(PhoneFraming.self, forKey: .unspotlitFraming)) ?? d.unspotlitFraming
        madeWithCocut = (try? c.decodeIfPresent(Bool.self, forKey: .madeWithCocut)) ?? d.madeWithCocut
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
    var start: Double
    var duration: Double
    let title: String?
    let isCard: Bool
    /// The clip's own crop to the video (pixels, top-left), if it has one.
    var crop: CGRect? = nil
    /// What a card shows ("Intro card", a section title), for the preview's list.
    var cardLabel: String? = nil
    /// The library clip this came from.
    var clipID: UUID? = nil
    /// Ring the athlete on a frozen first frame.
    var spotlight: Spotlight? = nil
    /// A spotlight still (rendered like a card), which cuts straight into its clip.
    var isSpotlight = false
    /// How it fills a phone-shaped frame (phone exports only).
    var framing: SegmentFraming? = nil
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
        let dir = Platform.moviesRoot.appending(path: "Cocut/Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Divider cards are shorter than the intro and end cards.
    var sectionCardSeconds: Double { Self.sectionCardSeconds(for: options) }
    nonisolated static func sectionCardSeconds(for options: ExportOptions) -> Double { min(options.cardSeconds, 3) }

    /// Estimated running time of the finished reel.
    func estimatedDuration(plan: [ReelEntry], profile: PlayerProfile) -> Double {
        var pieces = plan.map { entry -> Double in
            switch entry {
            case .clip(let clip):
                return clip.effectiveDuration
                    + (options.showSpotlights && clip.spotlight != nil ? ExportOptions.spotlightSeconds : 0)
            case .section: return sectionCardSeconds
            }
        }
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

    func export(plan: [ReelEntry], library: ClipLibrary, profile: PlayerProfile, headshot: PlatformImage?, to output: URL) {
        guard !isRunning else { return }
        let options = self.options
        task = Task {
            do {
                try await run(plan: plan, library: library, profile: profile, headshot: headshot,
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

    private func run(plan: [ReelEntry], library: ClipLibrary, profile: PlayerProfile, headshot: PlatformImage?,
                     options: ExportOptions, output: URL) async throws {
        let clipCount = plan.filter { if case .clip = $0 { return true } else { return false } }.count
        guard clipCount > 0 else { throw ExportError.noClips }
        let renderSize = options.renderSize()
        let fps = Int32(options.frameRate)
        let work = FileManager.default.temporaryDirectory.appending(path: "CocutExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Cards → short movies.
        let segments = try await Self.makeSegments(plan: plan, library: library, profile: profile, headshot: headshot,
                                                   options: options, renderSize: renderSize, fps: fps, work: work) {
            [weak self] message in self?.state = .preparing(message)
        }
        try Task.checkCancellation()

        // 2. Assemble.
        state = .preparing("Assembling \(clipCount) clips…")
        let accent = Platform.cgColor(profile.accentColor)
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

    /// The reel's pieces in order: cards drawn to short movies in `work`, and trimmed clips.
    static func makeSegments(plan: [ReelEntry], library: ClipLibrary, profile: PlayerProfile, headshot: PlatformImage?,
                             options: ExportOptions, renderSize: CGSize, fps: Int32, work: URL,
                             status: (String) -> Void) async throws -> [ReelSegment] {
        var segments: [ReelSegment] = []
        // Cards are drawn at the reel's size (phone reels get the tall layouts); spotlight stills
        // are drawn widescreen and framed like their clip.
        let cardSize = renderSize
        let stillSize = options.stillSize(for: renderSize)
        if options.includeIntro {
            status("Drawing the intro card…")
            segments.append(try await cardSegment(kind: .intro, label: "Intro card", profile: profile, headshot: headshot,
                                                  size: cardSize, fps: fps, seconds: options.cardSeconds, work: work,
                                                  progressBar: options.introProgressBar))
        }
        for entry in plan {
            try Task.checkCancellation()
            switch entry {
            case .section(let section):
                status("Drawing the “\(section.title)” card…")
                segments.append(try await cardSegment(kind: .section(section.title), label: section.title,
                                                      profile: profile, headshot: headshot, size: cardSize, fps: fps,
                                                      seconds: sectionCardSeconds(for: options), work: work))
            case .clip(let clip):
                let url = library.url(for: clip)
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    throw ExportError.unreadable(clip.title)
                }
                let duration = clip.trimEndSeconds - clip.trimStartSeconds
                guard duration > 0.1 else { continue }
                var framing: SegmentFraming?
                if options.shape.isPhone {
                    framing = await phoneFraming(for: clip, url: url, options: options, renderSize: renderSize,
                                                 number: Int(profile.featuredNumber.trimmingCharacters(in: .whitespaces)),
                                                 cacheDirectory: library.rootDirectory.appending(path: "Framing", directoryHint: .isDirectory),
                                                 status: status)
                }
                var still: ReelSegment?
                var moment = clip.trimStartSeconds
                if options.showSpotlights, let spot = clip.spotlight {
                    status("Drawing the spotlight on “\(clip.title)”…")
                    moment = spot.moment(in: clip)
                    let ringColor = options.spotlightColor.flatMap { Color(hex: $0) } ?? profile.accentColor
                    if case .window(let path) = framing {
                        // A phone reel: the hold is drawn in the clip's own window at that moment.
                        still = await spotlightSegment(clip: clip, url: url, spot: spot, at: moment, accent: Platform.cgColor(ringColor),
                                                       options: options, size: renderSize, fps: fps, work: work, phoneWindow: path)
                    } else {
                        still = await spotlightSegment(clip: clip, url: url, spot: spot, at: moment, accent: Platform.cgColor(ringColor),
                                                       options: options, size: stillSize, fps: fps, work: work)
                    }
                    if options.shape.isPhone { still?.framing = .whole }
                }
                func part(_ from: Double, _ to: Double, title: String?) -> ReelSegment {
                    var segment = ReelSegment(url: url, start: from, duration: to - from,
                                              title: title, isCard: false, crop: clip.cropRect, clipID: clip.id)
                    segment.framing = framing
                    return segment
                }
                if let still, moment - clip.trimStartSeconds >= 0.2 {
                    // Spotlight placed later in the clip: play up to it, hold it, then carry on.
                    segments.append(part(clip.trimStartSeconds, moment, title: clip.title))
                    segments.append(still)
                    if clip.trimEndSeconds - moment >= 0.1 { segments.append(part(moment, clip.trimEndSeconds, title: nil)) }
                } else {
                    if let still { segments.append(still) }
                    segments.append(part(clip.trimStartSeconds, clip.trimEndSeconds, title: clip.title))
                }
            }
        }
        if profile.showEndCard {
            status("Drawing the end card…")
            segments.append(try await cardSegment(kind: .end, label: "End card", profile: profile, headshot: headshot,
                                                  size: cardSize, fps: fps, seconds: options.cardSeconds, work: work,
                                                  madeWithCocut: options.madeWithCocut))
        }
        return segments
    }

    /// The clip's frame at the spotlight's moment as a short movie with the spotlight drawn on: the picture dims
    /// around the athlete and a ring in the team color snaps in. Made like a card (a still turned
    /// into frames), so it needs no video overlay. Nil if the frame can't be read.
    private static func spotlightSegment(clip: Clip, url: URL, spot: Spotlight, at moment: Double, accent: CGColor,
                                         options: ExportOptions, size: CGSize, fps: Int32, work: URL,
                                         phoneWindow: CameraPath? = nil) async -> ReelSegment? {
        guard let frame = await VideoFrames.firstFrame(url: url, at: moment, crop: clip.unitCrop) else {
            Log.error("Couldn't read the frame of \(clip.fileName) at \(moment)s for its spotlight")
            return nil
        }
        let fw = CGFloat(frame.width), fh = CGFloat(frame.height)
        // The part of the frame the clip shows (pixels, top-left origin): all of it, or without
        // the black bars the clip will have cropped away.
        var picture = CGRect(x: 0, y: 0, width: fw, height: fh)
        if clip.crop == nil, options.removeBlackBars {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let preferred = try? await track.load(.preferredTransform), preferred.isIdentity,
               let bars = await ReelComposer.contentRect(asset: asset, natural: natural,
                                                         range: CMTimeRange(start: CMTime(seconds: clip.trimStartSeconds, preferredTimescale: 600),
                                                                            end: CMTime(seconds: clip.trimEndSeconds, preferredTimescale: 600))) {
                let sx = fw / natural.width, sy = fh / natural.height
                picture = CGRect(x: bars.minX * sx, y: bars.minY * sy, width: bars.width * sx, height: bars.height * sy).integral
                    .intersection(picture)
            }
        }
        var shown = picture
        let drawSize = size
        var fill = options.fillFrame
        if let phoneWindow, size.height > 0 {
            // A phone reel: exactly the window the clip shows at this moment, so the hold and the
            // clip match frame for frame (as PhoneFrame.draw places it).
            let aspect = size.width / size.height
            let w: CGFloat, h: CGFloat
            if picture.width / picture.height > aspect {
                h = picture.height
                w = h * aspect
            } else {
                w = picture.width
                h = w / aspect
            }
            let c = phoneWindow.center(at: moment)
            let cx = min(picture.maxX - w / 2, max(picture.minX + w / 2, CGFloat(c.x) * fw))
            let cy = min(picture.maxY - h / 2, max(picture.minY + h / 2, CGFloat(c.y) * fh))
            shown = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).integral.intersection(picture)
            fill = true
        }
        guard !shown.isEmpty, let image = shown == CGRect(x: 0, y: 0, width: fw, height: fh) ? frame : frame.cropping(to: shown) else {
            return nil
        }
        // The ring was placed on the whole frame: move it into the part shown.
        var moved = spot
        moved.x = (spot.x * fw - shown.minX) / shown.width
        moved.y = (spot.y * fh - shown.minY) / shown.height
        moved.radius = spot.radius * fh / shown.height
        return await writeSpotlight(frame: image, clip: clip, spot: moved, accent: accent, shape: options.spotlightShape,
                                    ring: options.spotlightRing, fill: fill, size: drawSize, fps: fps, work: work)
    }

    private static func writeSpotlight(frame: CGImage, clip: Clip, spot: Spotlight, accent: CGColor, shape: SpotlightShape,
                                       ring: SpotlightRing, fill: Bool,
                                       size: CGSize, fps: Int32, work: URL) async -> ReelSegment? {
        let movie = work.appending(path: "spotlight-\(UUID().uuidString).mov")
        let seconds = ExportOptions.spotlightSeconds
        do {
            try await Task.detached(priority: .userInitiated) {
                try SpotlightMovieWriter.write(frame: frame, spot: spot, accent: accent, shape: shape, ring: ring, fill: fill,
                                               size: size, seconds: seconds, fps: fps, to: movie)
            }.value
        } catch {
            Log.error("Couldn't draw the spotlight for \(clip.fileName): \(error.localizedDescription)")
            return nil
        }
        return ReelSegment(url: movie, start: 0, duration: seconds, title: nil, isCard: true,
                           cardLabel: "Spotlight", clipID: clip.id, isSpotlight: true)
    }

    private static func cardSegment(kind: CardKind, label: String, profile: PlayerProfile, headshot: PlatformImage?,
                                    size: CGSize, fps: Int32, seconds: Double, work: URL,
                                    progressBar: Bool = false, madeWithCocut: Bool = false) async throws -> ReelSegment {
        guard let image = PlayerCardView.render(profile: profile, headshot: headshot, kind: kind, pixelSize: size,
                                                madeWithCocut: madeWithCocut) else {
            throw ExportError.cardFailed
        }
        // The progress bar uses the theme's highlight color over a faint track.
        var bar: CardMovieWriter.ProgressBar?
        if progressBar {
            let palette = CardPalette(theme: profile.theme, accent: profile.accentColor)
            bar = .init(fill: Platform.cgColor(palette.highlight), track: Platform.cgColor(palette.text.opacity(0.15)))
        }
        let url = work.appending(path: "card-\(UUID().uuidString).mov")
        // No fades: the very first frame is the intro card (so YouTube, Messages and Finder pick it
        // as the thumbnail), and the end card stays up until the video ends.
        try await Task.detached(priority: .userInitiated) {
            try CardMovieWriter.write(image, size: size, seconds: seconds, fps: fps,
                                      fadeIn: false, fadeOut: false, progress: bar, to: url)
        }.value
        return ReelSegment(url: url, start: 0, duration: seconds, title: nil, isCard: true, cardLabel: label)
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
        /// Where each piece sits on the reel's timeline.
        let pieces: [Piece]
    }

    struct Piece: Identifiable {
        let id: Int
        let segment: ReelSegment
        /// When the piece starts on the timeline (the start of its crossfade in, if any).
        let start: Double
        /// When it's fully on screen, after any crossfade in.
        let visibleStart: Double
        let duration: Double
        /// When its name caption shows, for clips with a name.
        let caption: (start: Double, duration: Double)?
    }

    /// Caption timing: shortly after the clip is fully on screen, for up to three seconds.
    static func captionTiming(visibleStart: Double, duration: Double) -> (start: Double, duration: Double) {
        (visibleStart + 0.3, min(3.0, max(1.0, duration - 0.8)))
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
        /// How the stored frames turn upright (for the phone compositor).
        let orientation: CGImagePropertyOrientation
        /// Time on the timeline.
        var length: Double { segment.duration }
    }

    /// `forPlayback` leaves out the Core Animation captions, which only work when exporting
    /// (the preview draws them itself from `pieces`).
    static func build(segments: [ReelSegment], options: ExportOptions,
                      renderSize: CGSize, accent: CGColor, forPlayback: Bool = false) async throws -> Built {
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
            var fixed = segment
            fixed.start = start.seconds
            fixed.duration = source.duration.seconds
            var crop: CGRect? = segment.crop
            if crop == nil, !segment.isCard, options.removeBlackBars, preferred.isIdentity {
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
                                 transform: transform, crop: crop, orientation: PlayerTracker.orientation(of: preferred)))
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
                // A spotlight still cuts straight into its clip (it's a frame of it), and from it
                // when it's placed partway through.
                let spotlight = loaded[i].segment.isSpotlight || loaded[i + 1].segment.isSpotlight
                    && loaded[i].segment.clipID == loaded[i + 1].segment.clipID && !loaded[i].segment.isCard
                overlaps[i] = spotlight ? 0 : min(ExportOptions.transitionSeconds,
                                  loaded[i].length / 3, loaded[i + 1].length / 3)
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
            cursor += item.length - (i < n - 1 ? overlaps[i] : 0)
        }
        let total = cursor

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        // The preview draws captions itself (from `pieces`) and leaves the mark out.
        let overlays = forPlayback ? [] : overlayPictures(loaded: loaded, starts: starts, overlaps: overlaps,
                                                          renderSize: renderSize, accent: accent,
                                                          captions: options.showClipNames, mark: options.madeWithCocut,
                                                          phone: options.shape.isPhone)
        videoComposition.customVideoCompositorClass = PhoneCompositor.self
        videoComposition.instructions = instructions(loaded: loaded, starts: starts, overlaps: overlaps,
                                                     tracks: videoTracks.map(\.trackID), total: composition.duration,
                                                     wide: !options.shape.isPhone, overlays: overlays)
        guard !videoComposition.instructions.isEmpty else { throw ExportError.composition("Nothing to show.") }

        // Audio: duck each clip out/in across crossfades.
        var audioMix: AVMutableAudioMix?
        if audioTracks.count == 2 {
            let params = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
            for i in 0..<(n - 1) where overlaps[i] > 0 {
                let from = starts[i] + loaded[i].length - overlaps[i]
                let range = CMTimeRange(start: time(from), duration: time(overlaps[i]))
                params[i % 2].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
                params[(i + 1) % 2].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range)
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = params
            audioMix = mix
        }

        let pieces = loaded.enumerated().map { i, item -> Piece in
            let visible = starts[i] + (i > 0 ? overlaps[i - 1] : 0)
            var caption: (start: Double, duration: Double)?
            if options.showClipNames, !item.segment.isCard,
               let title = item.segment.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                caption = captionTiming(visibleStart: visible, duration: item.segment.duration)
            }
            return Piece(id: i, segment: item.segment, start: starts[i], visibleStart: visible,
                         duration: item.length, caption: caption)
        }

        Log.info("Composed reel\(forPlayback ? " for preview" : ""): \(n) pieces, \(String(format: "%.1f", total))s at \(Int(renderSize.width))x\(Int(renderSize.height))")
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix, pieces: pieces)
    }

    /// The compositor's instructions: a solo stretch per piece and a blend into the next, tiling
    /// the timeline exactly. `wide`: widescreen pieces placed by their crop and transform.
    private static func instructions(loaded: [Loaded], starts: [Double], overlaps: [Double],
                                     tracks: [CMPersistentTrackID], total: CMTime,
                                     wide: Bool, overlays: [ReelOverlay]) -> [PhoneInstruction] {
        let timescale: CMTimeScale = 600
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }
        func layer(_ i: Int) -> PhoneLayer {
            let item = loaded[i]
            let framing = item.segment.framing ?? (item.segment.isCard ? .whole : .window(.fixed(x: 0.5, y: 0.5)))
            var layer = PhoneLayer(trackID: tracks[i % 2], orientation: item.orientation, picture: item.crop,
                                   pathSpace: item.segment.crop, framing: framing, timelineStart: starts[i],
                                   sourceStart: item.source.start.seconds, fadeOut: nil)
            if wide { layer.wide = (item.transform, item.crop) }
            return layer
        }
        var spans: [(from: Double, to: Double, layers: [PhoneLayer])] = []
        let n = loaded.count
        for i in 0..<n {
            let soloStart = starts[i] + (i > 0 ? overlaps[i - 1] : 0)
            let soloEnd = starts[i] + loaded[i].length - (i < n - 1 ? overlaps[i] : 0)
            if soloEnd - soloStart > 0.0005 { spans.append((soloStart, soloEnd, [layer(i)])) }
            if i < n - 1, overlaps[i] > 0 {
                var outgoing = layer(i)
                outgoing.fadeOut = (soloEnd, soloEnd + overlaps[i])
                spans.append((soloEnd, soloEnd + overlaps[i], [layer(i + 1), outgoing]))
            }
        }
        var ranges = spans.map { CMTimeRange(start: time($0.from), end: time($0.to)) }
        for k in ranges.indices.dropFirst() { ranges[k] = CMTimeRange(start: ranges[k - 1].end, end: ranges[k].end) }
        if !ranges.isEmpty {
            ranges[0] = CMTimeRange(start: .zero, end: ranges[0].end)
            ranges[ranges.count - 1] = CMTimeRange(start: ranges[ranges.count - 1].start, end: total)
        }
        return zip(ranges, spans).map { PhoneInstruction(timeRange: $0, layers: $1.layers, overlays: overlays) }
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

    /// What's drawn over the video when exporting: lower-third captions with each clip's name
    /// (faded in and out near the start of the clip), and the Cocut logo on every clip.
    private static func overlayPictures(loaded: [Loaded], starts: [Double], overlaps: [Double],
                                        renderSize: CGSize, accent: CGColor, captions: Bool, mark: Bool,
                                        phone: Bool) -> [ReelOverlay] {
        let scale = min(renderSize.width, renderSize.height) / 1080
        var overlays: [ReelOverlay] = []

        // The logo: bottom right, or bottom center in phone shapes (the right edge is covered by
        // the social app's buttons), while each clip is on screen, fading with it across transitions.
        if mark, let picture = madeWithCocutImage(scale: scale, logo: cocutLogo()) {
            let width = CGFloat(picture.width)
            let margin = 36 * scale
            let origin = CGPoint(x: (phone ? (renderSize.width - width) / 2 : renderSize.width - margin - width).rounded(),
                                 y: (phone ? renderSize.height * 0.035 : margin).rounded())
            for (i, item) in loaded.enumerated() where !item.segment.isCard {
                let from = starts[i] + (i > 0 ? overlaps[i - 1] : 0) / 2
                let to = starts[i] + item.length - (i < loaded.count - 1 ? overlaps[i] : 0) / 2
                guard to - from > 0.2 else { continue }
                let edge = min(0.25, (to - from) / 4) / (to - from)
                overlays.append(ReelOverlay(image: picture, origin: origin, start: from, end: to, fadeIn: edge, fadeOut: edge))
            }
        }

        for (i, item) in loaded.enumerated() where captions && !item.segment.isCard {
            guard let title = item.segment.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let picture = captionImage(title, accent: accent, scale: scale, maxWidth: renderSize.width * 0.8) else { continue }
            let timing = captionTiming(visibleStart: starts[i] + (i > 0 ? overlaps[i - 1] : 0),
                                       duration: item.segment.duration)
            overlays.append(ReelOverlay(image: picture, origin: CGPoint(x: 60 * scale, y: 70 * scale),
                                        start: timing.start, end: timing.start + timing.duration, fadeIn: 0.12, fadeOut: 0.15))
        }
        return overlays
    }

    /// A clip-name caption: the name in bold white on a dark rounded box with a bar in the team color.
    private static func captionImage(_ title: String, accent: CGColor, scale: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let font = PlatformFont.systemFont(ofSize: 40 * scale, weight: .bold)
        let textSize = (title as NSString).size(withAttributes: [.font: font])
        let padX = 28 * scale, barW = 8 * scale
        let height = (76 * scale).rounded()
        let width = min(maxWidth, textSize.width + padX * 2 + barW).rounded(.up)
        guard width >= 1, height >= 1,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
        context.clip()
        context.setFillColor(CGColor(gray: 0, alpha: 0.62))
        context.fill(box)
        context.setFillColor(accent)
        context.fill(CGRect(x: 0, y: 0, width: barW, height: height))
        let textFrame = CGRect(x: barW + padX, y: 0, width: width - barW - padX * 2, height: height)
        if let words = textImage(title, size: 40 * scale, in: textFrame.size) {
            context.draw(words, in: CGRect(origin: textFrame.origin, size: CGSize(width: words.width, height: words.height)))
        }
        return context.makeImage()
    }

    /// One line of bold white text, vertically centered in `size` and cut short with "…" if it's too long.
    private static func textImage(_ string: String, size fontSize: CGFloat, in size: CGSize) -> CGImage? {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
        }
        var drawn = line(string)
        if let short = CTLineCreateTruncatedLine(drawn, Double(size.width), .end, line("…")) { drawn = short }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(drawn, &ascent, &descent, &leading)
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width.rounded(.up)), height: Int(size.height.rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.textPosition = CGPoint(x: 0, y: (size.height - ascent - descent) / 2 + descent)
        CTLineDraw(drawn, context)
        return context.makeImage()
    }

    /// The mark's picture at the reel's scale: the Cocut logo (layers and wordmark, on a clear
    /// background), a little see-through, with a soft shadow. Nil where it isn't bundled.
    private static func madeWithCocutImage(scale: CGFloat, logo: CGImage?) -> CGImage? {
        guard let logo, logo.height > 0 else { return nil }
        let height = 130 * scale
        let width = height * CGFloat(logo.width) / CGFloat(logo.height)
        let pad = 10 * scale   // room for the shadow
        guard let context = CGContext(data: nil, width: Int((width + pad * 2).rounded(.up)),
                                      height: Int((height + pad * 2).rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAlpha(0.75)
        context.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 6 * scale,
                          color: CGColor(gray: 0, alpha: 0.5))
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(x: pad, y: pad, width: width, height: height))
        return context.makeImage()
    }

    /// The watermark logo (the Watermark image: docs/brand/cocut-logo.png at 512 px tall); nil
    /// where it isn't bundled.
    private static func cocutLogo() -> CGImage? {
        #if os(macOS)
        guard let image = PlatformImage(named: "Watermark") else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return PlatformImage(named: "Watermark")?.cgImage
        #endif
    }

}

// MARK: - Card movies

/// Turns a still card into a short H.264 movie, with an optional fade from or to black.
enum CardMovieWriter {
    /// Standard HD color tags, so every part of the reel is interpreted the same way.
    static let colorProperties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Colors for a bar that fills along the bottom while the card is up.
    struct ProgressBar: @unchecked Sendable {
        let fill: CGColor
        let track: CGColor
    }

    static func write(_ image: CGImage, size: CGSize, seconds: Double, fps: Int32,
                      fadeIn: Bool, fadeOut: Bool, progress: ProgressBar? = nil, to url: URL) throws {
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
            AVVideoColorPropertiesKey: CardMovieWriter.colorProperties,
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
            if let progress {
                // Each frame differs: the bar grows to full width over the card's time.
                let fraction = total > 1 ? CGFloat(i) / CGFloat(total - 1) : 1
                guard let frame = makeBuffer(image, width: width, height: height, alpha: alpha,
                                             bar: (progress, fraction)) else { throw ExportError.cardFailed }
                buffer = frame
            } else if alpha >= 1 {
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

    private static func makeBuffer(_ image: CGImage, width: Int, height: Int, alpha: CGFloat,
                                   bar: (ProgressBar, CGFloat)? = nil) -> CVPixelBuffer? {
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
        if let bar {
            let (colors, fraction) = bar
            // Along the very bottom (Core Graphics' origin is bottom-left).
            let h = max(4, CGFloat(height) * 10 / 1080)
            context.setFillColor(colors.track)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: h))
            context.setFillColor(colors.fill)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * fraction, height: h))
        }
        return buffer
    }
}

// MARK: - Spotlight movies

/// A clip's first frame held for a moment: the picture dims around the athlete and a ring
/// snaps in. Drawn frame by frame, like the cards.
enum SpotlightMovieWriter {
    static func write(frame: CGImage, spot: Spotlight, accent: CGColor, shape: SpotlightShape, ring: SpotlightRing = .standard,
                      fill: Bool, size: CGSize, seconds: Double, fps: Int32, to url: URL) throws {
        let width = Int(size.width), height = Int(size.height)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 6,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: CardMovieWriter.colorProperties,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw ExportError.cardFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.cardFailed }
        writer.startSession(atSourceTime: .zero)

        // Where the picture lands in the frame (fit, or fill when the reel fills the frame).
        let iw = CGFloat(frame.width), ih = CGFloat(frame.height)
        let s = fill ? max(size.width / iw, size.height / ih) : min(size.width / iw, size.height / ih)
        let pic = CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s)
        // Spotlight in Core Graphics coordinates (origin bottom-left).
        let center = CGPoint(x: pic.minX + spot.x * pic.width, y: size.height - (pic.minY + spot.y * pic.height))
        let radius = max(spot.radius * pic.height, 20 * size.height / 1080)
        let line = ring.width * size.height / 1080

        let total = max(1, Int(seconds * Double(fps)))
        for i in 0..<total {
            try Task.checkCancellation()
            let t = Double(i) / Double(fps)
            func ease(_ p: Double) -> Double { let c = min(1, max(0, p)); return 1 - (1 - c) * (1 - c) }
            let dim = 0.55 * ease(t / 0.25)
            let ringAlpha = ease(t / 0.2)
            let scale = 1.9 - 0.9 * ease(t / 0.35)
            guard let buffer = makeBuffer(width: width, height: height, draw: { ctx in
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.interpolationQuality = .high
                ctx.draw(frame, in: CGRect(x: pic.minX, y: size.height - pic.maxY, width: pic.width, height: pic.height))
                // Dim everything outside a circle around the athlete.
                let rx = radius * shape.aspect
                let hole = CGRect(x: center.x - rx * 1.15, y: center.y - radius * 1.15,
                                  width: rx * 2.3, height: radius * 2.3)
                ctx.addRect(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.addEllipse(in: hole)
                ctx.setFillColor(CGColor(gray: 0, alpha: dim))
                ctx.fillPath(using: .evenOdd)
                // The ring: snaps in from bigger, or a painted one is brushed on.
                guard ring != .none else { return }
                ctx.saveGState()
                if ring == .painted {
                    // Brushed on, unhurried.
                    ctx.setShadow(offset: .zero, blur: 8 * size.height / 1080, color: CGColor(gray: 0, alpha: 0.45))
                    for stroke in SpotlightRing.paintedStrokes(center: center, rx: rx * 1.05, ry: radius * 1.05, width: line,
                                                               progress: SpotlightRing.brushProgress(t), yUp: true) {
                        ctx.setFillColor(accent.copy(alpha: stroke.alpha) ?? accent)
                        ctx.addPath(stroke.path)
                        ctx.fillPath()
                    }
                } else {
                    let r = radius * scale, rxs = rx * scale
                    ctx.setShadow(offset: .zero, blur: 10 * size.height / 1080, color: CGColor(gray: 0, alpha: 0.6 * ringAlpha))
                    ctx.setStrokeColor(accent.copy(alpha: ringAlpha) ?? accent)
                    ctx.setLineWidth(line)
                    ctx.strokeEllipse(in: CGRect(x: center.x - rxs, y: center.y - r, width: rxs * 2, height: r * 2))
                }
                ctx.restoreGState()
            }) else { throw ExportError.cardFailed }
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

    private static func makeBuffer(width: Int, height: Int, draw: (CGContext) -> Void) -> CVPixelBuffer? {
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
        draw(context)
        return buffer
    }
}

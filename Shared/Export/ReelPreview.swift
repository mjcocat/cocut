import AVFoundation
import SwiftUI

/// Plays the reel as it will be exported (cards, order, trims, crops, transitions, captions,
/// sound) without rendering a file. Built at 720p so it's ready in a moment.
@MainActor
@Observable
final class ReelPreview {
    enum State: Equatable {
        case idle
        case building(String)
        case ready
        case failed(String)
    }

    /// Everything that changes what the reel looks like. When it differs from what was built,
    /// the preview offers to update.
    struct Signature: Equatable {
        var plan: [Data]
        var options: Data
        var profile: Data
        var headshot: ObjectIdentifier?
    }

    private(set) var state: State = .idle
    private(set) var player: AVPlayer?
    private(set) var pieces: [ReelComposer.Piece] = []
    private(set) var duration: Double = 0
    private(set) var builtSignature: Signature?
    /// Playback position, updated a few times a second.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var work: URL?
    /// A clip to jump to once the preview is ready.
    @ObservationIgnored private var pendingClipID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?

    static let renderSize = ReelResolution.hd720.size

    /// The export settings with what doesn't matter for the preview (resolution, frame rate) normalized.
    static func previewOptions(_ options: ExportOptions) -> ExportOptions {
        var o = options
        o.resolution = .hd720
        o.frameRate = 30
        return o
    }

    static func signature(plan: [ReelEntry], options: ExportOptions, profile: PlayerProfile,
                          headshot: PlatformImage?) -> Signature {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let entries = plan.map { entry -> Data in
            switch entry {
            case .clip(let clip): return (try? encoder.encode(clip)) ?? Data()
            case .section(let section): return (try? encoder.encode(section)) ?? Data()
            }
        }
        return Signature(plan: entries,
                         options: (try? encoder.encode(previewOptions(options))) ?? Data(),
                         profile: (try? encoder.encode(profile)) ?? Data(),
                         headshot: headshot.map(ObjectIdentifier.init))
    }

    var isBuilding: Bool { if case .building = state { return true } else { return false } }

    func build(plan: [ReelEntry], library: ClipLibrary, profile: PlayerProfile, headshot: PlatformImage?,
               options: ExportOptions) {
        task?.cancel()
        let options = Self.previewOptions(options)
        let signature = Self.signature(plan: plan, options: options, profile: profile, headshot: headshot)
        // Pick up roughly where the viewer was when rebuilding after an edit.
        let resumeAt = player == nil ? 0 : max(currentTime, 0.001)
        state = .building("Getting the preview ready…")

        task = Task {
            let work = FileManager.default.temporaryDirectory.appending(path: "CocutPreview-\(UUID().uuidString)")
            do {
                guard plan.contains(where: { if case .clip = $0 { return true } else { return false } }) else {
                    throw ExportError.noClips
                }
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let segments = try await ReelExporter.makeSegments(
                    plan: plan, library: library, profile: profile, headshot: headshot, options: options,
                    renderSize: Self.renderSize, fps: Int32(options.frameRate), work: work
                ) { [weak self] message in self?.state = .building(message) }
                try Task.checkCancellation()
                state = .building("Putting the clips together…")
                let accent = Platform.cgColor(profile.accentColor)
                let built = try await ReelComposer.build(segments: segments, options: options,
                                                         renderSize: Self.renderSize, accent: accent, forPlayback: true)
                try Task.checkCancellation()
                install(built, work: work, signature: signature, resumeAt: resumeAt)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: work)
            } catch {
                try? FileManager.default.removeItem(at: work)
                Log.error("Preview failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func install(_ built: ReelComposer.Built, work: URL, signature: Signature, resumeAt: Double) {
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix

        tearDownPlayer()
        if let old = self.work { try? FileManager.default.removeItem(at: old) }
        self.work = work

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
        pieces = built.pieces
        duration = built.composition.duration.seconds
        builtSignature = signature
        self.player = player
        state = .ready

        if let id = pendingClipID, let piece = pieces.first(where: { $0.segment.clipID == id }) {
            pendingClipID = nil
            play(piece: piece)
        } else if resumeAt > 0.5, resumeAt < duration - 0.5 {
            // Rebuilt after an edit: stay where the viewer was, paused.
            seek(to: resumeAt)
        } else if resumeAt == 0 {
            // Freshly opened: start watching.
            currentTime = 0
            player.play()
        } else {
            currentTime = 0
        }
    }

    /// Starts playback at a clip: right away if the preview is ready, otherwise once it's built.
    func startAt(clipID: UUID) {
        if state == .ready, let piece = pieces.first(where: { $0.segment.clipID == clipID }) {
            play(piece: piece)
        } else {
            pendingClipID = clipID
        }
    }

    // MARK: Playback

    func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration))
        currentTime = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(piece: ReelComposer.Piece) {
        seek(to: piece.start)
        player?.play()
    }

    func step(by offset: Int) {
        guard let index = currentPieceIndex else { return }
        // "Previous" restarts the current piece if it's been playing a moment.
        if offset < 0, currentTime - pieces[index].visibleStart > 1.5 {
            seek(to: pieces[index].start)
            return
        }
        let target = max(0, min(pieces.count - 1, index + offset))
        seek(to: pieces[target].start)
    }

    var currentPieceIndex: Int? {
        guard !pieces.isEmpty else { return nil }
        // The latest piece that has become fully visible (the incoming one during a crossfade).
        return pieces.lastIndex { $0.visibleStart <= currentTime + 0.01 } ?? 0
    }

    /// The caption showing now, with its opacity (fades in and out like the export).
    var currentCaption: (title: String, opacity: Double)? {
        for piece in pieces {
            guard let caption = piece.caption, let title = piece.segment.title else { continue }
            let t = currentTime - caption.start
            guard t >= 0, t <= caption.duration else { continue }
            let p = t / caption.duration
            let opacity = p < 0.12 ? p / 0.12 : (p > 0.85 ? (1 - p) / 0.15 : 1)
            return (title, max(0, min(1, opacity)))
        }
        return nil
    }

    // MARK: Teardown

    func close() {
        task?.cancel()
        task = nil
        tearDownPlayer()
        pieces = []
        builtSignature = nil
        state = .idle
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil
    }

    private func tearDownPlayer() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player = nil
        isPlaying = false
    }
}

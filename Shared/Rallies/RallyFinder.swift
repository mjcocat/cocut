#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A rally found in a match, which the user can adjust before using it.
struct Rally: Identifiable, Hashable {
    let id: UUID
    var start: Double
    var end: Double
    var isIncluded = true
    /// Added by hand rather than found.
    var isManual = false
    /// Jersey numbers seen in the rally (read automatically, then adjustable).
    var players: [Int] = []
    /// The user changed `players`; keep their list when rallies are rebuilt.
    var playersEdited = false

    var duration: Double { max(0, end - start) }

    init(start: Double, end: Double, isManual: Bool = false) {
        id = UUID()
        self.start = start
        self.end = end
        self.isManual = isManual
    }
}

/// The "Find Rallies" workflow: analyze a full match, review the rallies, then send them to the
/// clip library or export the match without the dead time.
@MainActor
@Observable
final class RallyFinder {
    enum State: Equatable {
        case empty
        case analyzing(Double)
        case review
        case working(String, Double?)
        case failed(String)
    }

    private(set) var state: State = .empty
    private(set) var sourceURL: URL?
    private(set) var analysis: RallyDetector.Result?
    var rallies: [Rally] = []
    var selectedID: Rally.ID?
    /// Start each rally at the serve whistle (shows the server getting ready) instead of just
    /// before the serve.
    var includeServeSetup = true {
        didSet {
            guard includeServeSetup != oldValue, !restoring else { return }
            pushUndo("Serve Setup", RallySnapshot(rallies: rallies, includeServeSetup: oldValue))
            rebuildRallies()
        }
    }

    // MARK: Undo

    private struct RallySnapshot {
        var rallies: [Rally]
        var includeServeSetup: Bool
    }

    private var undoStack: [(name: String, snapshot: RallySnapshot)] = []
    private var redoStack: [(name: String, snapshot: RallySnapshot)] = []
    @ObservationIgnored private var restoring = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var rallySnapshot: RallySnapshot { RallySnapshot(rallies: rallies, includeServeSetup: includeServeSetup) }

    private func checkpoint(_ name: String) { pushUndo(name, rallySnapshot) }

    private func pushUndo(_ name: String, _ snapshot: RallySnapshot) {
        undoStack.append((name, snapshot))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append((step.name, rallySnapshot))
        apply(step.snapshot)
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append((step.name, rallySnapshot))
        apply(step.snapshot)
    }

    private func apply(_ snapshot: RallySnapshot) {
        restoring = true
        includeServeSetup = snapshot.includeServeSetup
        restoring = false
        rallies = snapshot.rallies
        if let id = selectedID, !rallies.contains(where: { $0.id == id }) { selectedID = nil }
    }
    /// Playback skips the dead time between rallies (checked or not, so you can watch them all
    /// and check the ones you want).
    var watchCondensed = true
    /// Show only rallies with this jersey number.
    var playerFilter: Int?
    /// The team roster's numbers (supplied by the app), used to ignore referees and opponents.
    @ObservationIgnored var roster: () -> Set<Int> = { [] }

    // Playback
    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var skipping = false

    var duration: Double { analysis?.duration ?? 0 }
    var matchName: String { sourceURL?.deletingPathExtension().lastPathComponent ?? "Match" }
    /// Rallies shown in the list: all of them, or those with the filtered player.
    var visibleRallies: [Rally] {
        guard let n = playerFilter else { return rallies }
        return rallies.filter { $0.players.contains(n) }
    }
    /// Kept rallies that match the filter: what plays, and what gets added or exported.
    var keptRallies: [Rally] { visibleRallies.filter(\.isIncluded) }
    /// Every number on any rally, with how many rallies it's in.
    var playerCounts: [(number: Int, rallies: Int)] {
        var counts: [Int: Int] = [:]
        for r in rallies { for n in r.players { counts[n, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.number < $1.number }
    }
    var keptSeconds: Double { keptRallies.reduce(0) { $0 + $1.duration } }

    var selectedRally: Rally? { rallies.first { $0.id == selectedID } }

    func number(of rally: Rally) -> Int {
        (rallies.firstIndex { $0.id == rally.id } ?? 0) + 1
    }

    // MARK: Analysis

    #if os(macOS)
    func chooseMatch() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Match Video"
        panel.prompt = "Find Rallies"
        panel.message = "Pick a full match filmed from a fixed camera, ideally a tripod behind the end line."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        analyze(url)
    }
    #endif

    func analyze(_ url: URL) {
        task?.cancel()
        tearDownPlayer()
        sourceURL = url
        analysis = nil
        rallies = []
        selectedID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        state = .analyzing(0)
        Log.info("Finding rallies in \(url.lastPathComponent)")

        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await RallyDetector.analyze(url: url) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, case .analyzing = self.state else { return }
                            self.state = .analyzing(fraction)
                        }
                    }
                }.value
                try Task.checkCancellation()
                analysis = result
                rebuildRallies()
                makePlayer(url: url)
                state = .review
                Log.info("Found \(rallies.count) rallies: \(Int(keptSeconds))s of \(Int(result.duration))s")
            } catch is CancellationError {
                state = .empty
            } catch {
                Log.error("Rally analysis failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .analyzing = state { state = .empty }
    }

    /// Starts over with no match loaded.
    func reset() {
        cancel()
        tearDownPlayer()
        sourceURL = nil
        analysis = nil
        rallies = []
        selectedID = nil
        state = .empty
    }

    /// Recomputes rallies from the analysis (keeps hand-added rallies and unchecked ones).
    private func rebuildRallies() {
        guard let analysis else { return }
        let unchecked = rallies.filter { !$0.isIncluded && !$0.isManual }
        let edited = rallies.filter { $0.playersEdited && !$0.isManual }
        let manual = rallies.filter(\.isManual)
        let spans = RallyDetector.rallies(from: analysis, includeSetup: includeServeSetup)
        let frequent = RallyDetector.frequentNumbers(spans: spans, reads: analysis.numbers)
        let roster = self.roster()
        var fresh = spans.map { span -> Rally in
            var rally = Rally(start: span.start, end: span.end)
            rally.players = RallyDetector.players(in: span, reads: analysis.numbers, roster: roster, frequent: frequent)
            return rally
        }
        for i in fresh.indices where unchecked.contains(where: { Self.overlap($0, fresh[i]) > 0.5 * fresh[i].duration }) {
            fresh[i].isIncluded = false
        }
        for i in fresh.indices {
            if let old = edited.first(where: { Self.overlap($0, fresh[i]) > 0.5 * fresh[i].duration }) {
                fresh[i].players = old.players
                fresh[i].playersEdited = true
            }
        }
        rallies = (fresh + manual).sorted { $0.start < $1.start }
        if let id = selectedID, !rallies.contains(where: { $0.id == id }) { selectedID = nil }
    }

    private static func overlap(_ a: Rally, _ b: Rally) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }

    // MARK: Editing

    /// Checks or unchecks every rally in the list (only the filtered ones when a player filter is on).
    func setAllIncluded(_ included: Bool) {
        checkpoint("Keep All/None")
        let ids = Set(visibleRallies.map(\.id))
        for i in rallies.indices where ids.contains(rallies[i].id) {
            rallies[i].isIncluded = included
        }
    }

    func toggle(_ id: Rally.ID) {
        checkpoint("Keep")
        guard let i = rallies.firstIndex(where: { $0.id == id }) else { return }
        rallies[i].isIncluded.toggle()
    }

    func setStartToPlayhead() {
        checkpoint("Set Start")
        guard let i = selectedIndex else { return }
        rallies[i].start = min(currentTime, rallies[i].end - 0.5)
    }

    func setEndToPlayhead() {
        checkpoint("Set End")
        guard let i = selectedIndex else { return }
        rallies[i].end = max(currentTime, rallies[i].start + 0.5)
    }

    func nudge(start delta: Double) {
        checkpoint("Adjust Start")
        guard let i = selectedIndex else { return }
        rallies[i].start = max(0, min(rallies[i].start + delta, rallies[i].end - 0.5))
    }

    func nudge(end delta: Double) {
        checkpoint("Adjust End")
        guard let i = selectedIndex else { return }
        rallies[i].end = min(duration, max(rallies[i].end + delta, rallies[i].start + 0.5))
    }

    /// Adds a rally around the playhead (for one the finder missed).
    func addRallyAtPlayhead() {
        checkpoint("Add Rally")
        let start = max(0, currentTime - 2)
        let end = min(duration, currentTime + 8)
        guard end - start > 1 else { return }
        let rally = Rally(start: start, end: end, isManual: true)
        rallies.append(rally)
        rallies.sort { $0.start < $1.start }
        selectedID = rally.id
    }

    func addPlayer(_ number: Int, to id: Rally.ID) {
        checkpoint("Add Player")
        guard let i = rallies.firstIndex(where: { $0.id == id }), !rallies[i].players.contains(number) else { return }
        rallies[i].players.append(number)
        rallies[i].players.sort()
        rallies[i].playersEdited = true
    }

    func removePlayer(_ number: Int, from id: Rally.ID) {
        checkpoint("Remove Player")
        guard let i = rallies.firstIndex(where: { $0.id == id }) else { return }
        rallies[i].players.removeAll { $0 == number }
        rallies[i].playersEdited = true
    }

    func delete(_ id: Rally.ID) {
        checkpoint("Remove Rally")
        rallies.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    private var selectedIndex: Int? { rallies.firstIndex { $0.id == selectedID } }

    // MARK: Playback

    private func makePlayer(url: URL) {
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
        self.player = player
    }

    private func tick(_ t: Double) {
        currentTime = t
        guard watchCondensed, isPlaying, !skipping else { return }
        let kept = visibleRallies
        guard !kept.isEmpty else { return }
        // Inside a rally: carry on. In dead time: jump to the next rally in the list.
        if kept.contains(where: { t >= $0.start - 0.05 && t < $0.end }) { return }
        if let next = kept.first(where: { $0.start > t }) {
            skipping = true
            player?.seek(to: CMTime(seconds: next.start, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.skipping = false }
            }
        } else {
            player?.pause()
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if watchCondensed, let first = visibleRallies.first,
               !visibleRallies.contains(where: { currentTime >= $0.start && currentTime < $0.end }),
               visibleRallies.first(where: { $0.start > currentTime }) == nil {
                seek(to: first.start) // past the last rally: start over
            }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration))
        currentTime = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(_ rally: Rally) {
        selectedID = rally.id
        seek(to: rally.start)
        player?.play()
    }

    func step(by offset: Int) {
        let list = visibleRallies
        guard !list.isEmpty else { return }
        let index = list.lastIndex { $0.start <= currentTime + 0.05 }
        let target: Int
        if let index {
            if offset < 0, currentTime - list[index].start > 1.5 { target = index } else { target = index + offset }
        } else {
            target = offset > 0 ? 0 : -1
        }
        guard list.indices.contains(target) else { return }
        selectedID = list[target].id
        seek(to: list[target].start)
    }

    func pause() { player?.pause() }

    private func tearDownPlayer() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player = nil
        isPlaying = false
        currentTime = 0
    }

    // MARK: Output

    /// Copies each kept rally into the clip library, under a new section named after the match.
    func addToClips(library: ClipLibrary) {
        guard let sourceURL, !keptRallies.isEmpty else { return }
        let kept = keptRallies
        let numbers = kept.map { number(of: $0) }
        let base = matchName
        pause()
        state = .working("Adding rallies to Clips…", 0)
        task = Task {
            library.beginUndoGroup("Add Rallies")
            defer { library.endUndoGroup() }
            var ids: Set<Clip.ID> = []
            let asset = AVURLAsset(url: sourceURL)
            for (k, rally) in kept.enumerated() {
                if Task.isCancelled { break }
                state = .working("Adding rally \(k + 1) of \(kept.count) to Clips…", Double(k) / Double(kept.count))
                let destination = library.clipsDirectory.appending(path: "\(base) – Rally \(numbers[k]) \(UUID().uuidString.prefix(4)).mov")
                do {
                    try await Self.cut(asset: asset, range: rally, to: destination)
                    if let clip = await library.addClip(at: destination, title: "Rally \(numbers[k])") {
                        ids.insert(clip.id)
                        if !rally.players.isEmpty { library.setPlayers(rally.players, for: clip.id) }
                    }
                } catch {
                    Log.error("Couldn't copy rally \(numbers[k]): \(error.localizedDescription)")
                }
            }
            if !ids.isEmpty {
                _ = library.addSection(title: base, gathering: ids)
            }
            Log.info("Added \(ids.count) rallies from \(base) to Clips")
            state = .review
            lastAddedCount = ids.count
        }
    }

    /// Set after rallies are added to Clips, so the window can confirm it.
    var lastAddedCount: Int?

    #if os(macOS)
    /// Asks where to save, then exports the kept rallies back to back as one movie.
    func exportCondensed() {
        guard sourceURL != nil, !keptRallies.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Condensed Match"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = condensedFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exportCondensed(to: output)
    }
    #endif

    var condensedFileName: String { "\(matchName) – Rallies.mp4" }

    /// Set when a condensed export finishes, so the window can offer to share or show it.
    var lastCondensedURL: URL?

    /// Exports the kept rallies back to back as one movie at `output`.
    func exportCondensed(to output: URL) {
        guard let sourceURL, !keptRallies.isEmpty else { return }
        let kept = keptRallies
        pause()
        state = .working("Putting the rallies together…", nil)
        task = Task {
            do {
                try await Self.exportCondensed(source: sourceURL, rallies: kept, to: output) { [weak self] fraction in
                    self?.state = .working("Exporting… \(Int(fraction * 100))%", fraction)
                }
                state = .review
                lastCondensedURL = output
                Log.info("Exported condensed match to \(output.path(percentEncoded: false))")
                Platform.reveal([output])
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                state = .review
            } catch {
                Log.error("Condensed export failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelWork() {
        task?.cancel()
    }

    /// Returns to the rally list after an error during output.
    func dismissError() {
        state = analysis == nil ? .empty : .review
    }

    private static func cut(asset: AVURLAsset, range rally: Rally, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.sessionUnavailable
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: rally.start, preferredTimescale: 600),
                                        end: CMTime(seconds: rally.end, preferredTimescale: 600))
        try await session.export(to: url, as: .mov)
    }

    private static func exportCondensed(source: URL, rallies: [Rally], to output: URL,
                                        progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.unreadable(source.lastPathComponent) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        var size = CGSize(width: abs(upright.width), height: abs(upright.height))
        size.width -= size.width.truncatingRemainder(dividingBy: 2)
        size.height -= size.height.truncatingRemainder(dividingBy: 2)

        var options = ExportOptions()
        options.transition = .cut
        options.showClipNames = false
        options.includeSound = true
        options.removeBlackBars = false
        options.fillFrame = false
        options.frameRate = 30
        let segments = rallies.map {
            ReelSegment(url: source, start: $0.start, duration: $0.duration, title: nil, isCard: false)
        }
        let built = try await ReelComposer.build(segments: segments, options: options, renderSize: size,
                                                 accent: CGColor(gray: 1, alpha: 1))
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionUnavailable
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)
        let watcher = Task {
            for await s in session.states(updateInterval: 0.3) {
                if case .exporting(let p) = s { await progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: .mp4)
    }
}

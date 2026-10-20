#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A rally found in a match, which the user can adjust before using it.
struct Rally: Identifiable, Hashable, Codable {
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
    /// The user moved the start or end; keep their times when rallies are rebuilt.
    var timesEdited = false

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
    var rallies: [Rally] = [] {
        didSet { scheduleSave() }
    }
    var selectedID: Rally.ID?
    /// Start each rally at the serve whistle (shows the server getting ready) instead of just
    /// before the serve. Off by default: in a busy hall the setup is mostly walking around.
    var includeServeSetup = UserDefaults.standard.bool(forKey: "rallyIncludeServeSetup") {
        didSet {
            UserDefaults.standard.set(includeServeSetup, forKey: "rallyIncludeServeSetup")
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
        pendingMatch = url
    }
    #endif

    // MARK: Identify players

    /// Appearance examples per player: number (or `RallyDetector.otherTeam`) → examples. Per match.
    private(set) var taught: [Int: [[Float]]] = [:]
    /// Tracks the user identified: track → number (the whole stretch they were followed).
    private(set) var taughtTracks: [Int: Int] = [:] {
        didSet { scheduleSave() }
    }
    /// Players clicked on a frame who weren't followed: number → features.
    @ObservationIgnored private var frameExamples: [Int: [[Float]]] = [:]
    /// Players identified in earlier matches of this project.
    private(set) var memory = PlayerMemory()
    /// The memory's examples as features (without jersey color, since uniforms change).
    @ObservationIgnored private var priorExamples: [Int: [[Float]]] = [:]
    /// The project folder, where matches and the player memory are saved (supplied by the app).
    @ObservationIgnored var projectDirectory: () -> URL? = { nil }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Don't save while a saved match is being restored.
    @ObservationIgnored private var loadingState = false
    /// How many times each number was taught (answers and clicks), for the list.
    private(set) var taughtClicks: [Int: Int] = [:]
    /// How much of a followed player's frames must agree on who they look like for Cocut to
    /// decide on its own (0.5 = a simple majority; higher is stricter and asks about more).
    var matchSimilarity: Double = UserDefaults.standard.object(forKey: "rallyMatchAgreement") as? Double ?? 0.65 {
        didSet {
            UserDefaults.standard.set(matchSimilarity, forKey: "rallyMatchAgreement")
            if matchSimilarity != oldValue { refreshDecisions() }
        }
    }
    /// Who each followed player is (by track), and how sure Cocut is.
    private(set) var decisions: [Int: RallyDetector.TrackDecision] = [:]
    /// How many rallies each taught player was found in.
    private(set) var taughtFound: [Int: Int] = [:]
    /// Deciding is running (it takes a moment on a long match).
    private(set) var isMatching = false
    /// Tracks the user skipped in "Who's this?".
    private(set) var skippedTracks: Set<Int> = [] {
        didSet { scheduleSave() }
    }
    @ObservationIgnored private var matchTask: Task<Void, Never>?

    /// Whether this analysis has appearance data to identify players from.
    var canTeach: Bool { !(analysis?.people.isEmpty ?? true) }

    /// Followed players worth asking about, most useful first: ones Cocut couldn't decide, and
    /// ones whose read number disagrees with how they look. Short glimpses are left out.
    var reviewQueue: [RallyDetector.TrackDecision] {
        decisions.values
            .filter { ($0.source == .uncertain || $0.source == .conflict) && $0.count >= 4 && !$0.isGroup
                && !skippedTracks.contains($0.track) }
            .sorted { a, b in
                if (a.source == .conflict) != (b.source == .conflict) { return a.source == .conflict }
                return a.count > b.count
            }
    }

    /// How many followed players have been identified (any way) vs. not, counting only tracks
    /// long enough to ask about.
    var identifiedCounts: (identified: Int, unknown: Int) {
        let long = decisions.values.filter { $0.count >= 4 && !$0.isGroup }
        let known = long.filter { $0.number != nil && $0.source != .conflict }.count
        return (known, long.count - known)
    }

    /// The frames of one followed player.
    func sightings(ofTrack track: Int) -> [RallyDetector.PersonSighting] {
        analysis?.people.filter { $0.track == track } ?? []
    }

    /// The user says who a followed player is: `number`, or `RallyDetector.otherTeam`. It's also
    /// remembered for the project's next matches.
    func identify(track: Int, as number: Int) {
        let frames = sightings(ofTrack: track)
        guard !frames.isEmpty else { return }
        taughtTracks[track] = number
        addExamples(fromTrack: track, as: number)
        taughtClicks[number, default: 0] += 1
        let step = max(1, frames.count / 10)
        memory.add(stride(from: 0, to: frames.count, by: step).prefix(10).map { frames[$0].print }, label: number)
        if let project = projectDirectory() { memory.save(project: project) }
        Log.info("Identified a player as \(number == RallyDetector.otherTeam ? "other team" : "#\(number)") (\(frames.count) frames)")
        refreshDecisions()
    }

    func skip(track: Int) {
        skippedTracks.insert(track)
    }

    /// Up to 30 frames of a track, spread out, as examples of `number`.
    private func addExamples(fromTrack track: Int, as number: Int) {
        let frames = sightings(ofTrack: track)
        let step = max(1, frames.count / 30)
        taught[number, default: []].append(contentsOf: stride(from: 0, to: frames.count, by: step).prefix(30).map {
            RallyDetector.features(frames[$0].print, color: frames[$0].color)
        })
    }

    /// Forgets everything the project remembers about players (this match's answers stay).
    func clearMemory() {
        memory.clear()
        priorExamples = [:]
        if let project = projectDirectory() { memory.save(project: project) }
        refreshDecisions()
    }

    /// Teaches `number` from a player clicked at `time` (box in unit, bottom-left coordinates).
    /// When that player was followed during analysis, their whole track is identified too.
    func teach(_ number: Int, print: [Float], color: [Float], box: CGRect, time: Double) {
        let example = RallyDetector.features(print, color: color)
        if let people = analysis?.people,
           let match = people.filter({ abs($0.time - time) <= 0.6 && $0.track >= 0 })
               .max(by: { RallyDetector.overlap($0.box, box) < RallyDetector.overlap($1.box, box) }),
           RallyDetector.overlap(match.box, box) > 0.4 {
            taught[number, default: []].append(example)
            identify(track: match.track, as: number)
            return
        }
        taught[number, default: []].append(example)
        frameExamples[number, default: []].append(example)
        taughtClicks[number, default: 0] += 1
        scheduleSave()
        Log.info("Taught #\(number) from a frame (not followed)")
        refreshDecisions()
    }

    /// Forgets `number` in this match (the project memory keeps it unless cleared).
    func forget(_ number: Int) {
        taught[number] = nil
        taughtClicks[number] = nil
        frameExamples[number] = nil
        taughtTracks = taughtTracks.filter { $0.value != number }
        refreshDecisions()
    }

    /// Re-decides who every followed player is, in the background, then updates the rallies.
    private func refreshDecisions() {
        matchTask?.cancel()
        guard let people = analysis?.people, !people.isEmpty else {
            decisions = [:]
            taughtFound = [:]
            isMatching = false
            rebuildRallies()
            return
        }
        // This match's examples, plus players remembered from earlier matches.
        var taught = self.priorExamples
        for (number, examples) in self.taught { taught[number, default: []].append(contentsOf: examples) }
        let tracks = self.taughtTracks
        let agreement = Float(matchSimilarity)
        isMatching = true
        matchTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                RallyDetector.decide(people: people, taught: taught, taughtTracks: tracks, agreement: agreement)
            }.value
            guard !Task.isCancelled else { return }
            decisions = result
            isMatching = false
            rebuildRallies()
            let counts = identifiedCounts
            Log.info("Players: \(counts.identified) identified, \(counts.unknown) not (\(reviewQueue.count) to ask about)")
        }
    }

    // MARK: Saving

    /// Saves answers and edits a moment after the last change.
    private func scheduleSave() {
        guard !loadingState, let source = sourceURL, analysis != nil, let project = projectDirectory() else { return }
        saveTask?.cancel()
        let state = MatchStore.State(taughtTracks: taughtTracks, frameExamples: frameExamples, skippedTracks: skippedTracks,
                                     rallies: rallies, includeServeSetup: includeServeSetup)
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            MatchStore.saveState(state, source: source, project: project)
        }
    }

    /// Matches saved in this project, newest first.
    func recentMatches() -> [MatchStore.Summary] {
        guard let project = projectDirectory() else { return [] }
        return MatchStore.recent(project: project)
    }

    /// Reopens a saved match (instant: nothing is analyzed again).
    func open(_ match: MatchStore.Summary) {
        guard match.sourceExists else {
            state = .failed("“\(match.name)” isn't where it was when it was analyzed, so it can't be reopened.")
            return
        }
        if let project = projectDirectory(), let area = MatchStore.savedCourtArea(source: match.sourceURL, project: project) {
            courtArea = area
        }
        analyze(match.sourceURL)
    }

    func removeSaved(_ match: MatchStore.Summary) {
        guard let project = projectDirectory() else { return }
        MatchStore.remove(match, project: project)
    }

    /// After an analysis is ready (new or reopened): restore saved answers and edits, and load
    /// what the project remembers about players.
    private func restore(for source: URL) {
        loadingState = true
        defer { loadingState = false }
        taught = [:]
        taughtClicks = [:]
        frameExamples = [:]
        taughtTracks = [:]
        skippedTracks = []
        if let project = projectDirectory() {
            memory = PlayerMemory.load(project: project)
            priorExamples = memory.byLabel.mapValues { $0.map { RallyDetector.features($0, color: nil) } }
            if let saved = MatchStore.loadState(source: source, project: project) {
                restoring = true
                includeServeSetup = saved.includeServeSetup
                restoring = false
                frameExamples = saved.frameExamples
                taughtTracks = saved.taughtTracks
                skippedTracks = saved.skippedTracks
                for (number, examples) in frameExamples {
                    taught[number, default: []].append(contentsOf: examples)
                    taughtClicks[number, default: 0] += examples.count
                }
                for (track, number) in taughtTracks {
                    addExamples(fromTrack: track, as: number)
                    taughtClicks[number, default: 0] += 1
                }
                if !saved.rallies.isEmpty { rallies = saved.rallies }
                Log.info("Restored \(taughtTracks.count) answers and \(saved.rallies.count) rallies")
            }
            if !memory.examples.isEmpty {
                Log.info("Remembered players: \(memory.labels.map { $0 == RallyDetector.otherTeam ? "other team" : "#\($0)" }.joined(separator: ", "))")
            }
        }
    }

    /// A match waiting for its court area to be marked; the window shows the marking step and
    /// then calls `analyze`.
    var pendingMatch: URL?

    /// The air above the user's court (unit coordinates, top-left origin), marked on a frame of
    /// the match. Nil looks for the ball automatically across the top of the picture.
    var courtArea: CGRect? {
        didSet {
            if let a = courtArea {
                UserDefaults.standard.set([a.minX, a.minY, a.width, a.height], forKey: Self.courtAreaKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.courtAreaKey)
            }
        }
    }
    private static let courtAreaKey = "rallyCourtArea"

    /// The court area marked last time (the same camera spot is common).
    static var savedCourtArea: CGRect? {
        guard let v = UserDefaults.standard.array(forKey: courtAreaKey) as? [Double], v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    func analyze(_ url: URL) {
        task?.cancel()
        tearDownPlayer()
        sourceURL = url
        analysis = nil
        rallies = []
        selectedID = nil
        taught = [:]
        decisions = [:]
        taughtFound = [:]
        taughtTracks = [:]
        taughtClicks = [:]
        skippedTracks = []
        undoStack.removeAll()
        redoStack.removeAll()
        state = .analyzing(0)
        Log.info("Finding rallies in \(url.lastPathComponent)")
        let area = courtArea
        let project = projectDirectory()

        task = Task {
            do {
                let result: RallyDetector.Result
                let saved = await Task.detached(priority: .userInitiated) {
                    project.flatMap { MatchStore.load(source: url, courtArea: area, project: $0) }
                }.value
                if let saved {
                    result = saved
                    Log.info("Reopened the saved analysis of \(url.lastPathComponent)")
                } else {
                    result = try await Task.detached(priority: .userInitiated) {
                        try await RallyDetector.analyze(url: url, courtArea: area) { fraction in
                            Task { @MainActor [weak self] in
                                guard let self, case .analyzing = self.state else { return }
                                self.state = .analyzing(fraction)
                            }
                        }
                    }.value
                    try Task.checkCancellation()
                    if let project {
                        Task.detached(priority: .utility) { MatchStore.save(result, source: url, courtArea: area, project: project) }
                    }
                }
                analysis = result
                restore(for: url)
                if rallies.isEmpty { rebuildRallies() }
                refreshDecisions()
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
        taught = [:]
        decisions = [:]
        taughtFound = [:]
        taughtTracks = [:]
        taughtClicks = [:]
        skippedTracks = []
        state = .empty
    }

    /// Re-decides who's in each rally, e.g. after the team roster changes. No new analysis needed.
    func refreshPlayers() {
        guard analysis != nil else { return }
        rebuildRallies()
    }

    /// Recomputes rallies from the analysis (keeps hand-added rallies and unchecked ones).
    private func rebuildRallies() {
        guard let analysis else { return }
        let unchecked = rallies.filter { !$0.isIncluded && !$0.isManual }
        let edited = rallies.filter { $0.playersEdited && !$0.isManual }
        let manual = rallies.filter(\.isManual)
        let retimed = rallies.filter { $0.timesEdited && !$0.isManual }
        let spans = RallyDetector.rallies(from: analysis, includeSetup: includeServeSetup)
        let frequent = RallyDetector.frequentNumbers(spans: spans, reads: analysis.numbers)
        let roster = self.roster()
        var found: [Int: Int] = [:]
        let taughtNumbers = Set(taught.keys.filter { $0 >= 0 })
        var fresh = spans.map { span -> Rally in
            var rally = Rally(start: span.start, end: span.end)
            var players = Set(RallyDetector.players(in: span, reads: analysis.numbers, roster: roster, frequent: frequent))
            // Players followed through the rally: their number was read at some point, the user
            // said who they are, or they clearly look like someone known.
            let followed = RallyDetector.decidedPlayers(in: span, people: analysis.people, decisions: decisions,
                                                        allowed: roster.isEmpty ? frequent.union(taughtNumbers) : roster)
            players.formUnion(followed)
            for number in followed where taughtNumbers.contains(number) { found[number, default: 0] += 1 }
            rally.players = players.sorted()
            return rally
        }
        taughtFound = found
        for i in fresh.indices where unchecked.contains(where: { Self.overlap($0, fresh[i]) > 0.5 * fresh[i].duration }) {
            fresh[i].isIncluded = false
        }
        for i in fresh.indices {
            if let old = edited.first(where: { Self.overlap($0, fresh[i]) > 0.5 * fresh[i].duration }) {
                fresh[i].players = old.players
                fresh[i].playersEdited = true
            }
        }
        for i in fresh.indices {
            if let old = retimed.first(where: { Self.overlap($0, fresh[i]) > 0.5 * fresh[i].duration }) {
                fresh[i].start = old.start
                fresh[i].end = old.end
                fresh[i].timesEdited = true
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
        rallies[i].timesEdited = true
    }

    func setEndToPlayhead() {
        checkpoint("Set End")
        guard let i = selectedIndex else { return }
        rallies[i].end = max(currentTime, rallies[i].start + 0.5)
        rallies[i].timesEdited = true
    }

    func nudge(start delta: Double) {
        checkpoint("Adjust Start")
        guard let i = selectedIndex else { return }
        rallies[i].start = max(0, min(rallies[i].start + delta, rallies[i].end - 0.5))
        rallies[i].timesEdited = true
    }

    func nudge(end delta: Double) {
        checkpoint("Adjust End")
        guard let i = selectedIndex else { return }
        rallies[i].end = min(duration, max(rallies[i].end + delta, rallies[i].start + 0.5))
        rallies[i].timesEdited = true
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

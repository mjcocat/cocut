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

/// Whether a player is really in a stretch of the match (a rally), marked by the user in Check
/// Accuracy so Cocut's player lists can be scored. Stored by time, not by rally, so marks survive
/// rallies being found again.
struct TruthMark: Codable, Hashable, Sendable {
    var number: Int
    var start: Double
    var end: Double
    var present: Bool
}

/// How well Cocut lists one player on the rallies you marked.
struct PlayerAccuracy: Equatable {
    /// Rallies marked for this player.
    var marked = 0
    /// Marked as in.
    var present = 0
    /// Listed, and really in.
    var right = 0
    /// Listed, but not really in.
    var wrong = 0
    /// Really in, but not listed.
    var missed = 0

    /// When Cocut lists the player, how often it's right.
    var precision: Double? { right + wrong > 0 ? Double(right) / Double(right + wrong) : nil }
    /// Of the rallies the player is in, how many Cocut lists them in.
    var recall: Double? { present > 0 ? Double(right) / Double(present) : nil }
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
    /// How strict Cocut is about deciding a player on its own from how they look
    /// (0.5 loosest, 0.9 strictest; 0.65 uses the film's own learned threshold).
    var matchSimilarity: Double = UserDefaults.standard.object(forKey: "rallyMatchAgreement") as? Double ?? 0.65 {
        didSet {
            UserDefaults.standard.set(matchSimilarity, forKey: "rallyMatchAgreement")
            if matchSimilarity != oldValue { refreshDecisions() }
        }
    }
    /// Who each followed player is (by track), and how sure Cocut is.
    private(set) var decisions: [Int: RallyDetector.TrackDecision] = [:]
    /// The followed stretches grouped into people, biggest first.
    private(set) var people: [PlayerGrouping.Person] = []
    /// Frames of single players in all (for "how much is identified").
    private(set) var totalPlayerFrames = 0
    /// How many rallies each taught player was found in.
    private(set) var taughtFound: [Int: Int] = [:]
    /// Deciding is running (it takes a moment on a long match).
    private(set) var isMatching = false
    /// Goes up each time people are grouped again (so views can wait for an answer to apply).
    private(set) var groupingRevision = 0
    /// Tracks the user skipped in "Who's this?".
    private(set) var skippedTracks: Set<Int> = [] {
        didSet { scheduleSave() }
    }
    /// Stretches the user said aren't a player (unticked in "Who's this?"): track → numbers.
    private(set) var notTracks: [Int: Set<Int>] = [:] {
        didSet { scheduleSave() }
    }
    @ObservationIgnored private var matchTask: Task<Void, Never>?

    /// Whether this analysis has appearance data to identify players from.
    var canTeach: Bool { !(analysis?.people.isEmpty ?? true) }

    /// People worth asking about, biggest first: ones Cocut couldn't decide. Short glimpses, people
    /// never seen big enough to recognize, and people you skipped are left out.
    var reviewQueue: [PlayerGrouping.Person] {
        people.filter { person in
            guard person.number == nil, person.frames >= 6, person.maxHeight >= 0.12 else { return false }
            let skipped = person.trackFrames.reduce(0) { $0 + (skippedTracks.contains($1.key) ? $1.value : 0) }
            return skipped * 2 < person.frames
        }
    }

    /// Share of all player time (frames of single players) that is identified, 0...1.
    var identifiedShare: Double {
        guard totalPlayerFrames > 0 else { return 0 }
        let known = people.reduce(0) { $0 + ($1.number != nil ? $1.frames : 0) }
        return Double(known) / Double(totalPlayerFrames)
    }

    /// People identified (any way) vs. not, counting only people big enough to ask about.
    var identifiedCounts: (identified: Int, unknown: Int) {
        let big = people.filter { $0.frames >= 6 }
        let known = big.filter { $0.number != nil }.count
        return (known, big.count - known)
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

    /// The frames of one person (all their stretches).
    func sightings(of person: PlayerGrouping.Person) -> [RallyDetector.PersonSighting] {
        let tracks = Set(person.tracks)
        return analysis?.people.filter { tracks.contains($0.track) } ?? []
    }

    /// The user says who a person is. With nothing `rejected`, every stretch of them is identified
    /// at once. When the user unticked some close-ups (`rejected`), the person was a mix: only the
    /// ticked ones (`confirmed`) are identified, the unticked ones are noted as not this player,
    /// and the rest are grouped again with that to go on. Returns the stretches identified.
    @discardableResult
    func identify(_ person: PlayerGrouping.Person, as number: Int,
                  confirmed: Set<Int> = [], rejected: Set<Int> = []) -> Set<Int> {
        let tracks = rejected.isEmpty ? Set(person.tracks) : confirmed.intersection(person.tracks).subtracting(rejected)
        let frames = analysis?.people.filter { tracks.contains($0.track) } ?? []
        loadingState = true
        for track in tracks {
            taughtTracks[track] = number
            addExamples(fromTrack: track, as: number)
        }
        for track in rejected where person.tracks.contains(track) {
            notTracks[track, default: []].insert(number)
        }
        loadingState = false
        scheduleSave()
        let who = number == RallyDetector.otherTeam ? "other team" : "#\(number)"
        if !frames.isEmpty {
            taughtClicks[number, default: 0] += 1
            let step = max(1, frames.count / 15)
            memory.add(stride(from: 0, to: frames.count, by: step).prefix(15).map { frames[$0].print }, label: number)
            if let project = projectDirectory() { memory.save(project: project) }
        }
        if rejected.isEmpty {
            Log.info("Identified a person as \(who) (\(tracks.count) stretches, \(frames.count) frames)")
        } else {
            Log.info("Identified \(tracks.count) of \(person.tracks.count) stretches as \(who); \(rejected.count) unticked as not \(who)")
        }
        refreshDecisions()
        return tracks
    }

    func skip(_ person: PlayerGrouping.Person) {
        skippedTracks.formUnion(person.tracks)
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
        notTracks = notTracks.compactMapValues { nots in
            let left = nots.subtracting([number])
            return left.isEmpty ? nil : left
        }
        refreshDecisions()
    }

    /// Re-decides who every followed player is, in the background, then updates the rallies.
    private func refreshDecisions() {
        matchTask?.cancel()
        guard let sightings = analysis?.people, !sightings.isEmpty else {
            decisions = [:]
            people = []
            totalPlayerFrames = 0
            taughtFound = [:]
            isMatching = false
            rebuildRallies()
            return
        }
        // Players remembered from earlier matches, plus players clicked on a frame (by look alone).
        var remembered = memory.byLabel
        for (number, examples) in frameExamples {
            remembered[number, default: []].append(contentsOf: examples.map { Array($0.dropLast(3)) })
        }
        let prior = remembered
        let tracks = self.taughtTracks
        let nots = self.notTracks
        let strictness = Float(matchSimilarity - 0.65) * 0.3
        let compare = checking || !truth.isEmpty
        isMatching = true
        matchTask = Task {
            let start = Date()
            let result = await Task.detached(priority: .userInitiated) {
                PlayerGrouping.group(sightings: sightings, taughtTracks: tracks, notTracks: nots,
                                     remembered: prior, strictness: strictness)
            }.value
            guard !Task.isCancelled else { return }
            decisions = result.decisions
            people = result.people
            totalPlayerFrames = result.totalFrames
            isMatching = false
            groupingRevision += 1
            rebuildRallies()
            let counts = identifiedCounts
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            let threshold = String(format: "%.3f", result.threshold)
            let stretches = result.decisions.count - result.groupTracks.count
            let percent = Int((identifiedShare * 100).rounded())
            let biggest = result.people.first.map { "\($0.tracks.count) stretches / \($0.frames) frames" } ?? "none"
            Log.info("People: \(result.people.count) from \(stretches) stretches (\(result.groupTracks.count) group boxes left out), \(result.anchors) known from reads or answers, \(result.matched) matched by look, biggest \(biggest), same-person threshold \(threshold), \(seconds)s")
            Log.info("Players: \(counts.identified) identified, \(counts.unknown) not (\(reviewQueue.count) to ask about), \(percent)% of player time identified")

            // The v0.21 grouping on the same answers, so Check Accuracy can compare.
            guard compare else { return }
            let baseline = await Task.detached(priority: .utility) {
                PlayerGroupingBaseline.group(sightings: sightings, taughtTracks: tracks, remembered: prior, strictness: strictness)
            }.value
            guard !Task.isCancelled else { return }
            baselineDecisions = baseline.decisions
            baselineListed = listings(decisions: baseline.decisions)
            logAccuracy()
        }
    }

    // MARK: Check accuracy

    /// Which rallies players are really in, as marked by the user.
    private(set) var truth: [TruthMark] = [] {
        didSet { scheduleSave() }
    }
    /// Check Accuracy is open: also run the v0.21 grouping to compare against.
    private(set) var checking = false
    /// Players Cocut lists on each rally on its own (before the user's edits to the lists).
    private(set) var autoListed: [Rally.ID: Set<Int>] = [:]
    /// The same with the v0.21 grouping, when comparing.
    private(set) var baselineListed: [Rally.ID: Set<Int>] = [:]
    @ObservationIgnored private var baselineDecisions: [Int: RallyDetector.TrackDecision] = [:]
    @ObservationIgnored private var frequentNumbers: Set<Int> = []

    func startChecking() {
        guard !checking else { return }
        checking = true
        if baselineDecisions.isEmpty { refreshDecisions() }
    }

    func stopChecking() {
        checking = false
    }

    /// Whether `number` is really in `rally`, if the user marked it.
    func truthMark(_ number: Int, in rally: Rally) -> Bool? {
        truth.first { $0.number == number && Self.overlap($0, rally) > 0.5 * rally.duration }?.present
    }

    /// Marks whether `number` is really in `rally` (nil clears the mark).
    func setTruth(_ present: Bool?, number: Int, in rally: Rally) {
        var marks = truth.filter { !($0.number == number && Self.overlap($0, rally) > 0.5 * rally.duration) }
        if let present {
            marks.append(TruthMark(number: number, start: rally.start, end: rally.end, present: present))
        }
        truth = marks
        logAccuracy(only: number)
    }

    /// Numbers with marks, most marked first.
    var markedNumbers: [Int] {
        let counts = Dictionary(grouping: truth, by: \.number).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// How well Cocut lists `number` on the marked rallies, now or with the v0.21 grouping.
    func accuracy(of number: Int, baseline: Bool = false) -> PlayerAccuracy {
        let listed = baseline ? baselineListed : autoListed
        var score = PlayerAccuracy()
        for rally in rallies {
            guard let really = truthMark(number, in: rally) else { continue }
            let says = listed[rally.id]?.contains(number) ?? false
            score.marked += 1
            if really {
                score.present += 1
                if says { score.right += 1 } else { score.missed += 1 }
            } else if says {
                score.wrong += 1
            }
        }
        return score
    }

    /// Whether the v0.21 comparison is ready.
    var hasBaseline: Bool { !baselineListed.isEmpty }

    /// The players Cocut lists on each rally with `decisions`: numbers read in the rally, plus
    /// players followed through it (as when the rallies are built, without the user's edits).
    private func listings(decisions: [Int: RallyDetector.TrackDecision]) -> [Rally.ID: Set<Int>] {
        guard let analysis else { return [:] }
        let roster = self.roster()
        let frequent = frequentNumbers
        let taughtNumbers = Set(taught.keys.filter { $0 >= 0 })
        let allowed = roster.isEmpty ? frequent.union(taughtNumbers) : roster
        // Sightings by time, so each rally only looks at its own.
        let people = analysis.people.sorted { $0.time < $1.time }
        var out: [Rally.ID: Set<Int>] = [:]
        for rally in rallies {
            let span = RallyDetector.Span(start: rally.start, end: rally.end)
            var players = Set(RallyDetector.players(in: span, reads: analysis.numbers, roster: roster, frequent: frequent))
            let first = Self.firstIndex(people, atOrAfter: rally.start)
            var last = first
            while last < people.count && people[last].time <= rally.end { last += 1 }
            players.formUnion(RallyDetector.decidedPlayers(in: span, people: Array(people[first..<last]),
                                                           decisions: decisions, allowed: allowed))
            out[rally.id] = players
        }
        return out
    }

    private static func firstIndex(_ people: [RallyDetector.PersonSighting], atOrAfter time: Double) -> Int {
        var lo = 0, hi = people.count
        while lo < hi { let mid = (lo + hi) / 2; if people[mid].time < time { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private static func overlap(_ mark: TruthMark, _ rally: Rally) -> Double {
        max(0, min(mark.end, rally.end) - max(mark.start, rally.start))
    }

    /// Writes the scores to the log, so they can be compared across versions.
    private func logAccuracy(only number: Int? = nil) {
        for n in number.map({ [$0] }) ?? markedNumbers {
            let now = accuracy(of: n)
            guard now.marked > 0 else { continue }
            var line = "Accuracy #\(n), \(now.marked) rallies marked (\(now.present) in): " + Self.describe(now)
            if hasBaseline { line += "; v0.21 grouping: " + Self.describe(accuracy(of: n, baseline: true)) }
            Log.info(line)
        }
    }

    static func describe(_ a: PlayerAccuracy) -> String {
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
        return "\(a.right) right, \(a.wrong) wrong, \(a.missed) missed (right \(pct(a.precision)) of the time, finds \(pct(a.recall)))"
    }

    /// A plain-text report of the marks and scores for `number`, to paste somewhere.
    func accuracyReport(for number: Int) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let now = accuracy(of: number)
        var lines = ["Cocut \(version) · \(matchName) · #\(number)",
                     "Marked \(now.marked) rallies: in \(now.present), not in \(now.marked - now.present)",
                     "Now: " + Self.describe(now)]
        if hasBaseline { lines.append("v0.21 grouping: " + Self.describe(accuracy(of: number, baseline: true))) }
        let answered = Set(taughtTracks.values.filter { $0 >= 0 }).count
        lines.append("Answers: \(taughtTracks.count) stretches (\(answered) players), \(notTracks.count) unticked; \(Int((identifiedShare * 100).rounded()))% of player time identified")
        lines.append("")
        for rally in rallies {
            guard let really = truthMark(number, in: rally) else { continue }
            let says = autoListed[rally.id]?.contains(number) ?? false
            var line = "Rally \(self.number(of: rally)) \(Clip.format(rally.start)): really \(really ? "in" : "not in"), Cocut \(says ? "lists" : "doesn't list")"
            if hasBaseline {
                let before = baselineListed[rally.id]?.contains(number) ?? false
                line += ", v0.21 \(before ? "listed" : "didn't")"
            }
            if says != really { line += "  ✗" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Saving

    /// Saves answers and edits a moment after the last change.
    private func scheduleSave() {
        guard !loadingState, let source = sourceURL, analysis != nil, let project = projectDirectory() else { return }
        saveTask?.cancel()
        let state = MatchStore.State(taughtTracks: taughtTracks, frameExamples: frameExamples, skippedTracks: skippedTracks,
                                     rallies: rallies, includeServeSetup: includeServeSetup,
                                     analysisVersion: MatchStore.analysisVersion,
                                     answersVersion: MatchStore.answersVersion,
                                     notTracks: notTracks, truth: truth)
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
        notTracks = [:]
        truth = []
        if let project = projectDirectory() {
            memory = PlayerMemory.load(project: project)
            // Players remembered with an older appearance model can't be compared: start over.
            if let dims = analysis?.people.first?.print.count, memory.keepOnly(dims: dims) {
                memory.save(project: project)
                Log.info("Cocut now recognizes players with a new model, so earlier remembered players were cleared")
            }
            // v0.21 remembered players from answers that often covered several teammates at once.
            if PlayerMemory.upgrade(project: project, memory: &memory) {
                Log.info("Players remembered by an earlier version were often mixed up, so they were cleared")
            }
            priorExamples = memory.byLabel.mapValues { $0.map { RallyDetector.features($0, color: nil) } }
            if let saved = MatchStore.loadState(source: source, project: project) {
                restoring = true
                includeServeSetup = saved.includeServeSetup
                restoring = false
                // Answers about followed players belong to the analysis they were given on; rally
                // edits (times, checks, players) carry over to a fresh analysis.
                truth = saved.truth ?? []
                if saved.analysisVersion == MatchStore.analysisVersion, saved.answersVersion == MatchStore.answersVersion {
                    frameExamples = saved.frameExamples
                    taughtTracks = saved.taughtTracks
                    skippedTracks = saved.skippedTracks
                    notTracks = saved.notTracks ?? [:]
                } else if saved.analysisVersion != MatchStore.analysisVersion {
                    if !saved.taughtTracks.isEmpty {
                        Log.info("This match was analyzed again, so its earlier Who's This? answers were cleared")
                    }
                } else {
                    // Frame clicks are single players, so they still hold.
                    frameExamples = saved.frameExamples
                    if !saved.taughtTracks.isEmpty {
                        Log.info("Who's This? answers from an earlier version covered whole look-alike chains (often several teammates), so they were cleared")
                    }
                }
                for (number, examples) in frameExamples {
                    taught[number, default: []].append(contentsOf: examples)
                    taughtClicks[number, default: 0] += examples.count
                }
                for (track, number) in taughtTracks {
                    addExamples(fromTrack: track, as: number)
                    taughtClicks[number, default: 0] += 1
                }
                if !saved.rallies.isEmpty { rallies = saved.rallies }
                Log.info("Restored \(taughtTracks.count) answers, \(saved.rallies.count) rallies and \(truth.count) accuracy marks")
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
        people = []
        totalPlayerFrames = 0
        taughtFound = [:]
        taughtTracks = [:]
        taughtClicks = [:]
        skippedTracks = []
        notTracks = [:]
        truth = []
        autoListed = [:]
        baselineListed = [:]
        baselineDecisions = [:]
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
        people = []
        totalPlayerFrames = 0
        taughtFound = [:]
        taughtTracks = [:]
        taughtClicks = [:]
        skippedTracks = []
        notTracks = [:]
        truth = []
        autoListed = [:]
        baselineListed = [:]
        baselineDecisions = [:]
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
        frequentNumbers = frequent
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
        autoListed = listings(decisions: decisions)
        if !baselineDecisions.isEmpty { baselineListed = listings(decisions: baselineDecisions) }
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

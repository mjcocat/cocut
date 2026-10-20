import CryptoKit
import Foundation
import SwiftUI

/// Saves Find Rallies work in the project, so a match reopens instantly with your answers, and so
/// players you identified are remembered for the next match.
///
/// Layout, inside the project folder:
///
///     Matches/<key>/analysis.json   the analysis (appearance fingerprints left out)
///     Matches/<key>/people.bin      the fingerprints, 8-bit per value
///     Matches/<key>/state.json      your answers and rally edits
///     players.memory                fingerprints of identified players, across matches
enum MatchStore {
    /// Bump when the analysis changes enough that saved analyses should be redone.
    /// 4: appearance from the person re-identification model (not comparable with earlier prints).
    static let analysisVersion = 4
    /// Bump when answers mean something different, so saved answers are dropped (rally edits stay).
    /// 2: an answer covers only the stretches you confirmed (v0.21 answers covered whole chains
    /// of look-alikes, which often mixed teammates).
    static let answersVersion = 2

    struct Saved: Codable {
        var version: Int
        var sourcePath: String
        var sourceName: String
        var courtArea: CGRect?
        var savedAt: Date
        var result: RallyDetector.Result
    }

    /// Answers and edits for one match.
    struct State: Codable {
        var taughtTracks: [Int: Int] = [:]
        /// Players clicked on a frame that wasn't followed: number → features.
        var frameExamples: [Int: [[Float]]] = [:]
        var skippedTracks: Set<Int> = []
        var rallies: [Rally] = []
        var includeServeSetup = false
        /// The analysis the answers belong to (followed players are numbered per analysis).
        var analysisVersion: Int?
        /// How answers were given (see `MatchStore.answersVersion`). Optional, like the fields
        /// below, so states saved by earlier versions still load.
        var answersVersion: Int?
        /// Stretches you said aren't a player (unticked in Who's This?): track → numbers.
        var notTracks: [Int: Set<Int>]?
        /// Which rallies players are really in, marked in Check Accuracy. About the video, so
        /// they're kept when the match is analyzed again.
        var truth: [TruthMark]?
        /// Where the user is in the next-steps guide for this match.
        var guide: Guide?
    }

    /// The next-steps guide for one match: steps passed over, and whether it's hidden.
    struct Guide: Codable, Equatable {
        var hidden = false
        /// Steps the user passed over ("Skip", "Looks Fine", "Later", "Got It"), by raw value.
        var passed: Set<Int> = []
        /// Kept rallies were added to Clips or exported.
        var used = false
    }

    /// One saved match, for the Recent Matches list.
    struct Summary: Identifiable, Hashable {
        var id: String { key }
        var key: String
        var name: String
        var sourceURL: URL
        var savedAt: Date
        var rallyCount: Int
        var sourceExists: Bool
    }

    /// A stable name for a video: its file name, size and modification date.
    static func key(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let raw = "\(url.lastPathComponent)|\(size)|\(Int(date))"
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return "\(base.prefix(40))-\(digest)"
    }

    private static func folder(_ project: URL, _ key: String) -> URL {
        project.appending(path: "Matches/\(key)", directoryHint: .isDirectory)
    }

    // MARK: Analysis

    static func save(_ result: RallyDetector.Result, source: URL, courtArea: CGRect?, project: URL) {
        let dir = folder(project, key(for: source))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var slim = result
            for i in slim.people.indices { slim.people[i].print = [] }
            let saved = Saved(version: analysisVersion, sourcePath: storedPath(source),
                              sourceName: source.lastPathComponent, courtArea: courtArea, savedAt: Date(), result: slim)
            try JSONEncoder().encode(saved).write(to: dir.appending(path: "analysis.json"), options: .atomic)
            try Fingerprints.encode(result.people.map(\.print)).write(to: dir.appending(path: "people.bin"), options: .atomic)
            Log.info("Saved the analysis of \(source.lastPathComponent)")
        } catch {
            Log.error("Couldn't save the analysis: \(error.localizedDescription)")
        }
    }

    /// The saved analysis of `source`, if there is one from this version with the same court area.
    static func load(source: URL, courtArea: CGRect?, project: URL) -> RallyDetector.Result? {
        let dir = folder(project, key(for: source))
        guard let data = try? Data(contentsOf: dir.appending(path: "analysis.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == analysisVersion, sameArea(saved.courtArea, courtArea),
              let bin = try? Data(contentsOf: dir.appending(path: "people.bin")) else { return nil }
        var result = saved.result
        let prints = Fingerprints.decode(bin)
        guard prints.count == result.people.count else { return nil }
        for i in result.people.indices { result.people[i].print = prints[i] }
        return result
    }

    private static func sameArea(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.minX - b.minX) < 0.005 && abs(a.minY - b.minY) < 0.005
            && abs(a.width - b.width) < 0.005 && abs(a.height - b.height) < 0.005
        default: return false
        }
    }

    /// The court area a saved match was analyzed with.
    static func savedCourtArea(source: URL, project: URL) -> CGRect?? {
        let dir = folder(project, key(for: source))
        guard let data = try? Data(contentsOf: dir.appending(path: "analysis.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == analysisVersion else { return nil }
        return .some(saved.courtArea)
    }

    /// Videos inside Cocut's own folder are stored relative to it: on iPhone and iPad the app's
    /// folder moves when the app is reinstalled.
    private static let rootMarker = "cocut-root:"

    private static func storedPath(_ url: URL) -> String {
        let root = Platform.moviesRoot.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        return path.hasPrefix(root) ? rootMarker + String(path.dropFirst(root.count)) : path
    }

    private static func resolvedURL(_ stored: String) -> URL {
        guard stored.hasPrefix(rootMarker) else { return URL(filePath: stored) }
        return Platform.moviesRoot.appending(path: String(stored.dropFirst(rootMarker.count)))
    }

    // MARK: Answers and edits

    static func saveState(_ state: State, source: URL, project: URL) {
        let dir = folder(project, key(for: source))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: dir.appending(path: "state.json"), options: .atomic)
        } catch {
            Log.error("Couldn't save Find Rallies changes: \(error.localizedDescription)")
        }
    }

    static func loadState(source: URL, project: URL) -> State? {
        let url = folder(project, key(for: source)).appending(path: "state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    // MARK: Recent matches

    static func recent(project: URL) -> [Summary] {
        let root = project.appending(path: "Matches", directoryHint: .isDirectory)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Summary? in
            guard let data = try? Data(contentsOf: dir.appending(path: "analysis.json")),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            let url = resolvedURL(saved.sourcePath)
            let state = loadState(source: url, project: project)
            return Summary(key: dir.lastPathComponent, name: saved.sourceName, sourceURL: url, savedAt: saved.savedAt,
                           rallyCount: state?.rallies.count ?? 0,
                           sourceExists: FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    static func remove(_ summary: Summary, project: URL) {
        try? FileManager.default.removeItem(at: folder(project, summary.key))
    }
}

/// Fingerprints of players identified in earlier matches, kept with the project. Each answer adds
/// a few; at most 150 per player are kept (the newest).
struct PlayerMemory {
    struct Example {
        var label: Int
        var print: [Float]
    }

    private(set) var examples: [Example] = []
    static let perPlayer = 150

    var labels: [Int] { Array(Set(examples.map(\.label))).sorted() }

    /// Drops examples made by a different appearance model (their length differs). Returns
    /// whether any were dropped.
    mutating func keepOnly(dims: Int) -> Bool {
        let before = examples.count
        examples.removeAll { $0.print.count != dims }
        return examples.count != before
    }

    static func url(project: URL) -> URL { project.appending(path: "players.memory") }

    static func load(project: URL) -> PlayerMemory {
        guard let data = try? Data(contentsOf: url(project: project)) else { return PlayerMemory() }
        // Labels first (Int32 each, after a count), then the fingerprints.
        guard data.count >= 4 else { return PlayerMemory() }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        guard count >= 0, data.count >= 4 + count * 4 else { return PlayerMemory() }
        let labels = (0..<count).map { i in
            Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + i * 4, as: Int32.self) })
        }
        let prints = Fingerprints.decode(data.subdata(in: (4 + count * 4)..<data.count))
        guard prints.count == count else { return PlayerMemory() }
        return PlayerMemory(examples: zip(labels, prints).map { Example(label: $0, print: $1) })
    }

    func save(project: URL) {
        var data = Data()
        var count = Int32(examples.count)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for e in examples {
            var label = Int32(e.label)
            withUnsafeBytes(of: &label) { data.append(contentsOf: $0) }
        }
        data.append(Fingerprints.encode(examples.map(\.print)))
        do {
            try data.write(to: Self.url(project: project), options: .atomic)
        } catch {
            Log.error("Couldn't save the player memory: \(error.localizedDescription)")
        }
    }

    mutating func add(_ prints: [[Float]], label: Int) {
        examples.append(contentsOf: prints.map { Example(label: label, print: $0) })
        let mine = examples.indices.filter { examples[$0].label == label }
        if mine.count > Self.perPlayer {
            let drop = Set(mine.prefix(mine.count - Self.perPlayer))
            examples = examples.indices.filter { !drop.contains($0) }.map { examples[$0] }
        }
    }

    mutating func forget(_ label: Int) {
        examples.removeAll { $0.label == label }
    }

    mutating func clear() { examples = [] }

    /// What the remembered players were learned from; bumped when earlier ones can't be trusted.
    /// 2: v0.22 (v0.21 answers often covered several teammates at once).
    static let version = 2

    /// Clears what was remembered by an earlier version, once per project. Returns whether
    /// anything was cleared.
    static func upgrade(project: URL, memory: inout PlayerMemory) -> Bool {
        let marker = project.appending(path: "players.memory-version")
        let saved = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard saved != version else { return false }
        try? String(version).write(to: marker, atomically: true, encoding: .utf8)
        guard !memory.examples.isEmpty else { return false }
        memory.clear()
        memory.save(project: project)
        return true
    }

    /// Examples grouped by player, for seeding a new match.
    var byLabel: [Int: [[Float]]] {
        Dictionary(grouping: examples, by: \.label).mapValues { $0.map(\.print) }
    }
}

/// Unit-length fingerprints stored compactly: per fingerprint a Float32 scale, then one signed
/// byte per value. Plenty for comparing them; about a quarter of the size.
enum Fingerprints {
    static func encode(_ prints: [[Float]]) -> Data {
        let dims = prints.first?.count ?? 0
        var data = Data()
        var header = (Int32(prints.count), Int32(dims))
        withUnsafeBytes(of: &header.0) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &header.1) { data.append(contentsOf: $0) }
        data.reserveCapacity(8 + prints.count * (4 + dims))
        for p in prints {
            var values = p.count == dims ? p : [Float](repeating: 0, count: dims)
            var scale = values.map(abs).max() ?? 0
            if scale == 0 { scale = 1 }
            withUnsafeBytes(of: &scale) { data.append(contentsOf: $0) }
            for i in values.indices { values[i] = (values[i] / scale * 127).rounded() }
            data.append(contentsOf: values.map { UInt8(bitPattern: Int8(max(-127, min(127, $0)))) })
        }
        return data
    }

    static func decode(_ data: Data) -> [[Float]] {
        guard data.count >= 8 else { return [] }
        return data.withUnsafeBytes { raw -> [[Float]] in
            let count = Int(raw.loadUnaligned(fromByteOffset: 0, as: Int32.self))
            let dims = Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            guard count >= 0, dims >= 0, raw.count >= 8 + count * (4 + dims) else { return [] }
            var out: [[Float]] = []
            out.reserveCapacity(count)
            var offset = 8
            for _ in 0..<count {
                let scale = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                offset += 4
                var v = [Float](repeating: 0, count: dims)
                for i in 0..<dims {
                    v[i] = Float(Int8(bitPattern: raw[offset + i])) / 127 * scale
                }
                offset += dims
                // Back to unit length (rounding nudges it slightly).
                let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
                if norm > 0 { for i in 0..<dims { v[i] /= norm } }
                out.append(v)
            }
            return out
        }
    }
}


/// Matches analyzed before in this project: reopen one instantly, with your answers and edits.
struct RecentMatchesList: View {
    let finder: RallyFinder
    @State private var matches: [MatchStore.Summary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !matches.isEmpty {
                Text("Recent matches").font(.headline)
                ForEach(matches.prefix(6)) { match in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.name).lineLimit(1)
                            Text(match.sourceExists
                                 ? "\(match.savedAt.formatted(date: .abbreviated, time: .shortened))\(match.rallyCount > 0 ? " · \(match.rallyCount) rallies" : "")"
                                 : "Video moved or deleted")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { finder.open(match) }
                            .disabled(!match.sourceExists)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Remove from Recent", role: .destructive) {
                            finder.removeSaved(match)
                            matches = finder.recentMatches()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear { matches = finder.recentMatches() }
    }
}

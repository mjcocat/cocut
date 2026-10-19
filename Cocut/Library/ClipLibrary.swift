import AVFoundation
import AppKit
import Foundation
import SwiftUI

struct Clip: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let fileName: String
    let createdAt: Date
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    /// Trim points in seconds from the start of the file; nil means untrimmed.
    var trimStart: Double?
    var trimEnd: Double?
    /// Left out of the exported reel (kept in the library).
    var isExcluded: Bool?
    /// Workflow tags (never shown in the exported reel).
    var tagIDs: [UUID]?
    /// The part of the recording that's the video (pixels, top-left origin); nil shows it all.
    var crop: CropRect?
    /// Auto-crop has run for this clip (so it isn't repeated), or the user turned cropping off.
    var cropChecked: Bool?
    /// What happens in the clip and who did it ("Kill by #11"). Workflow only; not in the reel.
    var plays: [PlayTag]?

    var playList: [PlayTag] { plays ?? [] }
    /// Jersey numbers of players in the clip (from Find Rallies, or added by hand).
    var players: [Int]?
    var playerList: [Int] { players ?? [] }
    /// Everyone in the clip: listed players plus anyone tagged in a play.
    var allPlayers: Set<Int> { Set(playerList + playList.compactMap(\.player)) }

    var cropRect: CGRect? { crop?.cgRect }
    /// Crop as fractions of the frame, for thumbnails at any size.
    var unitCrop: CGRect? {
        guard let r = crop?.cgRect, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGRect(x: r.minX / CGFloat(pixelWidth), y: r.minY / CGFloat(pixelHeight),
                      width: r.width / CGFloat(pixelWidth), height: r.height / CGFloat(pixelHeight))
    }

    var isIncluded: Bool { isExcluded != true }
    var trimStartSeconds: Double { trimStart ?? 0 }
    var trimEndSeconds: Double { trimEnd ?? duration }
    var tags: [UUID] { tagIDs ?? [] }

    var isTrimmed: Bool { trimStart != nil || trimEnd != nil }
    var effectiveDuration: Double { max(0, (trimEnd ?? duration) - (trimStart ?? 0)) }
    var resolutionText: String {
        if let r = crop { return "\(Int(r.width))×\(Int(r.height))" }
        return "\(pixelWidth)×\(pixelHeight)"
    }
    var durationText: String { Clip.format(effectiveDuration) }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct CropRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A volleyball action, for tagging who did what in a clip.
enum PlayAction: String, Codable, CaseIterable, Identifiable {
    case kill, block, ace, dig, set, pass, serve, error

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var plural: String { self == .pass ? "Passes" : "\(title)s" }
    /// Typed shortcut: the first letter, except Serve (V) so S can be Set.
    var key: Character {
        switch self {
        case .serve: return "v"
        default: return rawValue.first!
        }
    }
    var symbol: String {
        switch self {
        case .kill: return "bolt.fill"
        case .block: return "hand.raised.fill"
        case .ace: return "star.fill"
        case .dig: return "arrow.down.to.line"
        case .set: return "arrow.up.forward"
        case .pass: return "arrow.turn.up.right"
        case .serve: return "figure.volleyball"
        case .error: return "xmark.octagon"
        }
    }
}

/// One play in a clip: an action, optionally by a jersey number.
struct PlayTag: Codable, Hashable, Identifiable {
    var action: PlayAction
    var player: Int?

    var id: String { "\(action.rawValue)-\(player.map(String.init) ?? "")" }
    var label: String { player.map { "\(action.title) · #\($0)" } ?? action.title }

    /// Parses quick entry like "k11", "Kill 11", "d 5", "#7 block", or "b".
    static func parse(_ text: String) -> PlayTag? {
        let lower = text.lowercased()
        let letters = lower.filter(\.isLetter)
        let digits = lower.filter(\.isNumber)
        guard !letters.isEmpty else { return nil }
        let action = PlayAction.allCases.first { $0.rawValue == letters }
            ?? PlayAction.allCases.first { letters.count > 1 && $0.rawValue.hasPrefix(letters) }
            ?? PlayAction.allCases.first { $0.key == letters.first }
        guard let action else { return nil }
        return PlayTag(action: action, player: digits.isEmpty ? nil : Int(digits.prefix(3)))
    }
}

/// A player on the team's roster.
struct RosterPlayer: Codable, Hashable, Identifiable {
    var number: Int
    var name: String
    var id: Int { number }
    var label: String { name.isEmpty ? "#\(number)" : "#\(number) \(name)" }
}

/// A heading in the clip list ("Kills", "Blocks"). Clips below it, up to the next heading,
/// belong to it. It can optionally put a divider card into the exported reel.
struct ReelSection: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var showCard = false

    init(title: String) { self.title = title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Section"
        showCard = (try? c.decodeIfPresent(Bool.self, forKey: .showCard)) ?? false
    }
}

enum TagColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

struct ClipTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color: TagColor

    init(name: String, color: TagColor) {
        self.name = name
        self.color = color
    }
}

/// One row of the library list, in reel order.
enum LibraryItem: Codable, Identifiable, Hashable {
    case clip(Clip)
    case section(ReelSection)

    var id: UUID {
        switch self {
        case .clip(let clip): return clip.id
        case .section(let section): return section.id
        }
    }

    var clip: Clip? { if case .clip(let c) = self { return c } else { return nil } }
    var section: ReelSection? { if case .section(let s) = self { return s } else { return nil } }
}

/// What goes into the exported reel, in order.
enum ReelEntry {
    case section(ReelSection)
    case clip(Clip)
}

/// Clips live in ~/Movies/Cocut/Clips, with a JSON index (clip order, sections, tags) alongside.
@MainActor
@Observable
final class ClipLibrary {
    private(set) var items: [LibraryItem] = []
    private(set) var tags: [ClipTag] = []
    private(set) var roster: [RosterPlayer] = []
    /// Where new recordings and imports are added: the end of this section, or the end of the list.
    var newClipsSectionID: UUID? {
        didSet { if newClipsSectionID != oldValue { save() } }
    }
    var recentlyAddedID: Clip.ID?

    let rootDirectory: URL
    let clipsDirectory: URL
    private var indexURL: URL { rootDirectory.appending(path: "library.json") }

    private struct LibraryFile: Codable {
        var version = 2
        var items: [LibraryItem]
        var tags: [ClipTag]
        var newClipsSectionID: UUID?
        var roster: [RosterPlayer]?
    }

    init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies")
        rootDirectory = movies.appending(path: "Cocut", directoryHint: .isDirectory)
        clipsDirectory = rootDirectory.appending(path: "Clips", directoryHint: .isDirectory)

        // Carry clips over from the app's previous name.
        let legacy = movies.appending(path: "Highlight Creator", directoryHint: .isDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path(percentEncoded: false)),
           !fm.fileExists(atPath: rootDirectory.path(percentEncoded: false)) {
            try? fm.moveItem(at: legacy, to: rootDirectory)
            Log.info("Moved clip library from \(legacy.path(percentEncoded: false))")
        }
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Reading

    var clips: [Clip] { items.compactMap(\.clip) }
    var sections: [ReelSection] { items.compactMap(\.section) }
    var includedClips: [Clip] { clips.filter(\.isIncluded) }
    var totalDuration: Double { clips.reduce(0) { $0 + $1.effectiveDuration } }

    func url(for clip: Clip) -> URL {
        clipsDirectory.appending(path: clip.fileName)
    }

    func clip(withID id: Clip.ID?) -> Clip? {
        guard let id else { return nil }
        return items.lazy.compactMap(\.clip).first { $0.id == id }
    }

    func section(withID id: UUID?) -> ReelSection? {
        guard let id else { return nil }
        return items.lazy.compactMap(\.section).first { $0.id == id }
    }

    func tag(withID id: UUID) -> ClipTag? {
        tags.first { $0.id == id }
    }

    /// 1-based position among clips (sections don't count).
    func number(of clip: Clip) -> Int {
        (clips.firstIndex { $0.id == clip.id } ?? 0) + 1
    }

    /// The section a clip sits under, if any.
    func sectionContaining(_ clipID: Clip.ID) -> ReelSection? {
        var current: ReelSection?
        for item in items {
            switch item {
            case .section(let s): current = s
            case .clip(let c): if c.id == clipID { return current }
            }
        }
        return nil
    }

    func clips(in sectionID: UUID) -> [Clip] {
        guard let start = items.firstIndex(where: { $0.id == sectionID }) else { return [] }
        var out: [Clip] = []
        for item in items[(start + 1)...] {
            if item.section != nil { break }
            if let clip = item.clip { out.append(clip) }
        }
        return out
    }

    /// The exported reel: included clips in order, with a divider card for each section that
    /// asks for one and has at least one included clip.
    var reelPlan: [ReelEntry] {
        var plan: [ReelEntry] = []
        var pendingSection: ReelSection?
        for item in items {
            switch item {
            case .section(let s):
                pendingSection = s.showCard ? s : nil
            case .clip(let c):
                guard c.isIncluded else { continue }
                if let s = pendingSection {
                    plan.append(.section(s))
                    pendingSection = nil
                }
                plan.append(.clip(c))
            }
        }
        return plan
    }

    // MARK: Clips

    @discardableResult
    func addClip(at url: URL, title: String? = nil) async -> Clip? {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var size = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            size = natural
        }

        let clip = Clip(
            id: UUID(),
            title: title ?? nextTitle(),
            fileName: url.lastPathComponent,
            createdAt: .now,
            duration: duration.isFinite ? duration : 0,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height)
        )
        items.insert(.clip(clip), at: insertionIndex())
        recentlyAddedID = clip.id
        save()
        return clip
    }

    /// End of the "new clips" section, or the end of the list.
    private func insertionIndex() -> Int {
        guard let sectionID = newClipsSectionID,
              let start = items.firstIndex(where: { $0.id == sectionID }) else { return items.count }
        var index = start + 1
        while index < items.count, items[index].section == nil { index += 1 }
        return index
    }

    private func updateClip(_ id: Clip.ID, _ change: (inout Clip) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), var clip = items[index].clip else { return }
        change(&clip)
        items[index] = .clip(clip)
    }

    func setIncluded(_ ids: Set<Clip.ID>, _ included: Bool) {
        for id in ids { updateClip(id) { $0.isExcluded = included ? nil : true } }
        save()
    }

    func setTrim(_ clip: Clip, start: Double?, end: Double?) {
        updateClip(clip.id) { c in
            c.trimStart = (start ?? 0) > 0.01 ? start : nil
            if let end, end < c.duration - 0.01 { c.trimEnd = end } else { c.trimEnd = nil }
        }
        save()
    }

    /// Looks for the video inside a screen recording and crops the clip to it (once per clip).
    func autoCrop(_ clipID: Clip.ID, force: Bool = false) async -> Bool {
        guard let clip = clip(withID: clipID), force || clip.cropChecked != true else { return false }
        let rect = await VideoCropDetector.detect(url: url(for: clip))
        updateClip(clipID) { c in
            c.cropChecked = true
            if let rect { c.crop = CropRect(rect) }
        }
        save()
        if let rect {
            Log.info("Cropped \(clip.fileName) to the video: \(Int(rect.width))x\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY))")
        }
        return rect != nil
    }

    func removeCrop(_ clipID: Clip.ID) {
        updateClip(clipID) { c in
            c.crop = nil
            c.cropChecked = true
        }
        save()
    }

    func rename(_ clip: Clip, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateClip(clip.id) { $0.title = trimmed }
        save()
    }

    /// Moves the file to the Trash so a mistaken delete is recoverable.
    func delete(_ clip: Clip) {
        delete([clip])
    }

    func delete(_ batch: [Clip]) {
        let ids = Set(batch.map(\.id))
        for clip in batch {
            try? FileManager.default.trashItem(at: url(for: clip), resultingItemURL: nil)
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// Reorders rows (clips and section headings) as shown in the list.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Copies video files into the library. Returns how many were imported.
    func importFiles(_ urls: [URL]) async -> Int {
        var imported = 0
        for source in urls {
            let asset = AVURLAsset(url: source)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
                Log.error("Import skipped (no video): \(source.lastPathComponent)")
                continue
            }
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            var destination = clipsDirectory.appending(path: "\(base).\(ext)")
            var n = 2
            while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                destination = clipsDirectory.appending(path: "\(base) \(n).\(ext)")
                n += 1
            }
            do {
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                Log.error("Import failed for \(source.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            if await addClip(at: destination, title: base) != nil { imported += 1 }
        }
        return imported
    }

    func revealInFinder(_ clip: Clip? = nil) {
        if let clip {
            NSWorkspace.shared.activateFileViewerSelecting([url(for: clip)])
        } else {
            NSWorkspace.shared.open(clipsDirectory)
        }
    }

    // MARK: Sections

    /// Adds a section heading. With clips given, the heading goes where the first of them is and
    /// those clips are gathered under it; otherwise it's added at the end of the list.
    @discardableResult
    func addSection(title: String, gathering clipIDs: Set<Clip.ID> = []) -> ReelSection {
        let section = ReelSection(title: uniqueSectionTitle(title))
        if clipIDs.isEmpty {
            items.append(.section(section))
        } else {
            let moving = items.filter { clipIDs.contains($0.id) }
            let anchor = items.firstIndex { clipIDs.contains($0.id) } ?? items.count
            let before = items[..<anchor].filter { !clipIDs.contains($0.id) }
            let after = items[anchor...].filter { !clipIDs.contains($0.id) }
            items = Array(before) + [.section(section)] + moving + Array(after)
        }
        save()
        return section
    }

    /// Moves clips to the end of a section, or to the top of the list (before any section) when nil.
    func moveClips(_ clipIDs: Set<Clip.ID>, toSection sectionID: UUID?) {
        let moving = items.filter { clipIDs.contains($0.id) && $0.clip != nil }
        guard !moving.isEmpty else { return }
        var rest = items.filter { !clipIDs.contains($0.id) || $0.clip == nil }
        var index: Int
        if let sectionID, let start = rest.firstIndex(where: { $0.id == sectionID }) {
            index = start + 1
            while index < rest.count, rest[index].section == nil { index += 1 }
        } else {
            index = rest.firstIndex { $0.section != nil } ?? rest.count
        }
        rest.insert(contentsOf: moving, at: index)
        items = rest
        save()
    }

    func renameSection(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSection(id) { $0.title = trimmed }
    }

    func setSectionCard(_ id: UUID, _ show: Bool) {
        updateSection(id) { $0.showCard = show }
    }

    /// Removes the heading only; its clips stay where they are (joining the section above).
    func deleteSection(_ id: UUID) {
        items.removeAll { $0.id == id }
        if newClipsSectionID == id { newClipsSectionID = nil }
        save()
    }

    private func updateSection(_ id: UUID, _ change: (inout ReelSection) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), var section = items[index].section else { return }
        change(&section)
        items[index] = .section(section)
        save()
    }

    private func uniqueSectionTitle(_ base: String) -> String {
        let used = Set(sections.map(\.title))
        guard used.contains(base) else { return base }
        var n = 2
        while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Tags

    @discardableResult
    func addTag(name: String, color: TagColor? = nil) -> ClipTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let palette = TagColor.allCases
        let tag = ClipTag(name: trimmed, color: color ?? palette[tags.count % palette.count])
        tags.append(tag)
        save()
        return tag
    }

    func renameTag(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index].name = trimmed
        save()
    }

    func setTagColor(_ id: UUID, _ color: TagColor) {
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index].color = color
        save()
    }

    func deleteTag(_ id: UUID) {
        tags.removeAll { $0.id == id }
        for clip in clips where clip.tags.contains(id) {
            updateClip(clip.id) { c in
                c.tagIDs = c.tags.filter { $0 != id }
                if c.tagIDs?.isEmpty == true { c.tagIDs = nil }
            }
        }
        save()
    }

    /// Adds the tag to all the clips, or removes it if they all already have it.
    // MARK: Plays and roster

    /// Adds a play to clips (once each).
    func addPlay(_ play: PlayTag, to clipIDs: Set<Clip.ID>) {
        for id in clipIDs {
            updateClip(id) { c in
                var list = c.playList
                if !list.contains(play) { list.append(play) }
                c.plays = list
            }
        }
        if let number = play.player, !roster.contains(where: { $0.number == number }) {
            roster.append(RosterPlayer(number: number, name: ""))
            roster.sort { $0.number < $1.number }
        }
        save()
    }

    func removePlay(_ play: PlayTag, from clipIDs: Set<Clip.ID>) {
        for id in clipIDs {
            updateClip(id) { c in
                let list = c.playList.filter { $0 != play }
                c.plays = list.isEmpty ? nil : list
            }
        }
        save()
    }

    func setPlayers(_ numbers: [Int], for clipID: Clip.ID) {
        let list = Array(Set(numbers)).sorted()
        updateClip(clipID) { $0.players = list.isEmpty ? nil : list }
        save()
    }

    func addPlayer(number: Int, name: String) {
        guard number >= 0, number < 1000 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = roster.firstIndex(where: { $0.number == number }) {
            if !trimmed.isEmpty { roster[i].name = trimmed }
        } else {
            roster.append(RosterPlayer(number: number, name: trimmed))
            roster.sort { $0.number < $1.number }
        }
        save()
    }

    func renamePlayer(_ number: Int, to name: String) {
        guard let i = roster.firstIndex(where: { $0.number == number }) else { return }
        roster[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Removes a player from the roster (their plays stay on the clips).
    func removePlayer(_ number: Int) {
        roster.removeAll { $0.number == number }
        save()
    }

    func player(_ number: Int) -> RosterPlayer? {
        roster.first { $0.number == number }
    }

    /// "#11 Lilah" when the roster has a name, else "#11".
    func playerLabel(_ number: Int) -> String {
        player(number)?.label ?? "#\(number)"
    }

    /// Actions that appear on at least one clip.
    var usedActions: [PlayAction] {
        let used = Set(clips.flatMap { $0.playList.map(\.action) })
        return PlayAction.allCases.filter(used.contains)
    }

    func toggleTag(_ tagID: UUID, on clipIDs: Set<Clip.ID>) {
        let targets = clips.filter { clipIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let allHave = targets.allSatisfy { $0.tags.contains(tagID) }
        for clip in targets {
            updateClip(clip.id) { c in
                var set = c.tags
                if allHave {
                    set.removeAll { $0 == tagID }
                } else if !set.contains(tagID) {
                    set.append(tagID)
                }
                c.tagIDs = set.isEmpty ? nil : set
            }
        }
        save()
    }

    // MARK: Persistence

    private func nextTitle() -> String {
        let all = clips
        let used = Set(all.map(\.title))
        var n = all.count + 1
        while used.contains("Clip \(n)") { n += 1 }
        return "Clip \(n)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        var loadedItems: [LibraryItem]
        var target: UUID?
        if let file = try? Self.decoder.decode(LibraryFile.self, from: data) {
            loadedItems = file.items
            tags = file.tags
            roster = file.roster ?? []
            target = file.newClipsSectionID
        } else if let clips = try? Self.decoder.decode([Clip].self, from: data) {
            // Version 1: a plain list of clips.
            loadedItems = clips.map { .clip($0) }
            Log.info("Upgraded clip library to version 2")
        } else {
            Log.error("Couldn't read library.json; starting empty")
            return
        }
        // Drop entries whose file was removed in Finder.
        loadedItems.removeAll { item in
            guard let clip = item.clip else { return false }
            return !FileManager.default.fileExists(atPath: url(for: clip).path(percentEncoded: false))
        }
        items = loadedItems
        // Set after `items`: this property saves on change.
        newClipsSectionID = target
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = LibraryFile(items: items, tags: tags, newClipsSectionID: newClipsSectionID,
                               roster: roster.isEmpty ? nil : roster)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

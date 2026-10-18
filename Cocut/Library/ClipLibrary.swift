import AVFoundation
import AppKit
import Foundation

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

    var isTrimmed: Bool { trimStart != nil || trimEnd != nil }
    var effectiveDuration: Double { max(0, (trimEnd ?? duration) - (trimStart ?? 0)) }
    var resolutionText: String { "\(pixelWidth)×\(pixelHeight)" }
    var durationText: String { Clip.format(effectiveDuration) }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Clips live in ~/Movies/Cocut/Clips, with a small JSON index alongside.
@MainActor
@Observable
final class ClipLibrary {
    private(set) var clips: [Clip] = []
    var recentlyAddedID: Clip.ID?

    let rootDirectory: URL
    let clipsDirectory: URL
    private var indexURL: URL { rootDirectory.appending(path: "library.json") }

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

    var totalDuration: Double { clips.reduce(0) { $0 + $1.effectiveDuration } }

    func url(for clip: Clip) -> URL {
        clipsDirectory.appending(path: clip.fileName)
    }

    @discardableResult
    func addClip(at url: URL) async -> Clip? {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var size = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            size = natural
        }

        let clip = Clip(
            id: UUID(),
            title: nextTitle(),
            fileName: url.lastPathComponent,
            createdAt: .now,
            duration: duration.isFinite ? duration : 0,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height)
        )
        clips.append(clip)
        recentlyAddedID = clip.id
        save()
        return clip
    }

    func setTrim(_ clip: Clip, start: Double?, end: Double?) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let s = (start ?? 0) > 0.01 ? start : nil
        let e = end.map { $0 < clips[index].duration - 0.01 ? $0 : nil } ?? nil
        clips[index].trimStart = s
        clips[index].trimEnd = e
        save()
    }

    func clip(withID id: Clip.ID?) -> Clip? {
        guard let id else { return nil }
        return clips.first { $0.id == id }
    }

    func rename(_ clip: Clip, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].title = trimmed
        save()
    }

    /// Moves the file to the Trash so a mistaken delete is recoverable.
    func delete(_ clip: Clip) {
        try? FileManager.default.trashItem(at: url(for: clip), resultingItemURL: nil)
        clips.removeAll { $0.id == clip.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func revealInFinder(_ clip: Clip? = nil) {
        if let clip {
            NSWorkspace.shared.activateFileViewerSelecting([url(for: clip)])
        } else {
            NSWorkspace.shared.open(clipsDirectory)
        }
    }

    // MARK: Persistence

    private func nextTitle() -> String {
        let used = Set(clips.map(\.title))
        var n = clips.count + 1
        while used.contains("Clip \(n)") { n += 1 }
        return "Clip \(n)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder.decode([Clip].self, from: data) else { return }
        // Drop entries whose file was removed in Finder.
        clips = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path(percentEncoded: false)) }
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
        guard let data = try? encoder.encode(clips) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

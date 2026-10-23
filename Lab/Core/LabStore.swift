import Foundation

/// A clip in Cocut Lab: a stretch of a video, where the player was pointed out (a spotlight from
/// Cocut, or the first head marked), and the number they wear.
struct LabClip: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    /// The video file (absolute path).
    var video: String
    var start: Double
    var end: Double
    /// The clip's crop as fractions of the upright frame (x, y, width, height; top-left origin).
    var crop: [Double]?
    /// Cocut's spotlight ring: x, y (fractions of the cropped picture, top-left origin), radius,
    /// and the moment it's placed at (video seconds) when that isn't the clip's start.
    var spotlight: [Double]?

    /// When the spotlight is placed: its moment, or the clip's start.
    var spotlightTime: Double {
        guard let s = spotlight, s.count >= 4 else { return start }
        return max(start, s[3])
    }
    /// Jersey number of the player to follow; nil uses the lab's.
    var number: Int?
    /// Clips in the same group (a match, a project) are held out together when checking that
    /// tuned settings work on clips they weren't tuned on.
    var group: String

    var videoURL: URL { URL(fileURLWithPath: video) }
    var unitCrop: CGRect? { crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
}

/// Where the player really is at one moment, marked by hand: their head (Vision coordinates of
/// the whole upright frame: 0...1, origin bottom-left), or that they can't be seen.
struct LabMark: Codable, Hashable {
    enum Kind: String, Codable { case head, hidden, unsure }
    var time: Double
    var kind: Kind
    var x: Double?
    var y: Double?

    static func head(_ time: Double, _ x: Double, _ y: Double) -> LabMark { LabMark(time: time, kind: .head, x: x, y: y) }
}

/// The lab folder:
///
///     lab.json                 the clips and the default jersey number
///     detections/<id>.json     people found in each clip (ClipDetections)
///     labels/<id>.json         marks, one every half second
///     reports/                 tuning reports
struct LabStore {
    static let step = 0.5

    struct Index: Codable {
        var version = 1
        var number: Int?
        var clips: [LabClip] = []
    }

    let folder: URL
    var index: Index

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Cocut Lab", directoryHint: .isDirectory)
    }

    init(folder: URL) {
        self.folder = folder
        let fm = FileManager.default
        for sub in ["detections", "labels", "reports"] {
            try? fm.createDirectory(at: folder.appending(path: sub, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: folder.appending(path: "lab.json")),
           let decoded = try? JSONDecoder().decode(Index.self, from: data) {
            index = decoded
        } else {
            index = Index()
        }
    }

    var clips: [LabClip] { index.clips }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(index) { try? data.write(to: folder.appending(path: "lab.json"), options: .atomic) }
    }

    mutating func add(_ clip: LabClip) {
        // The same stretch of the same video isn't added twice.
        guard !index.clips.contains(where: { $0.video == clip.video && abs($0.start - clip.start) < 0.01 && abs($0.end - clip.end) < 0.01 })
        else { return }
        index.clips.append(clip)
    }

    mutating func remove(_ id: UUID) {
        index.clips.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: detectionsURL(id))
        try? FileManager.default.removeItem(at: labelsURL(id))
    }

    func clip(_ key: String) -> LabClip? {
        // By id, id prefix, or title.
        index.clips.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
            ?? index.clips.first { $0.title.caseInsensitiveCompare(key) == .orderedSame }
    }

    func number(for clip: LabClip) -> Int? { clip.number ?? index.number }

    // MARK: Detections and labels

    func detectionsURL(_ id: UUID) -> URL { folder.appending(path: "detections/\(id.uuidString).json") }
    func labelsURL(_ id: UUID) -> URL { folder.appending(path: "labels/\(id.uuidString).json") }

    func hasDetections(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: detectionsURL(id).path(percentEncoded: false)) }

    func detections(_ id: UUID) -> ClipDetections? {
        guard let data = try? Data(contentsOf: detectionsURL(id)) else { return nil }
        return try? JSONDecoder().decode(ClipDetections.self, from: data)
    }

    func saveDetections(_ d: ClipDetections, for id: UUID) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: detectionsURL(id), options: .atomic) }
    }

    func marks(_ id: UUID) -> [LabMark] {
        guard let data = try? Data(contentsOf: labelsURL(id)),
              let marks = try? JSONDecoder().decode([LabMark].self, from: data) else { return [] }
        return marks.sorted { $0.time < $1.time }
    }

    func saveMarks(_ marks: [LabMark], for id: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(marks.sorted { $0.time < $1.time }) {
            try? data.write(to: labelsURL(id), options: .atomic)
        }
    }

    /// Sets (or clears, with nil) the mark at `time`.
    func setMark(_ mark: LabMark?, at time: Double, for id: UUID) {
        var list = marks(id).filter { abs($0.time - time) > 0.01 }
        if let mark { list.append(mark) }
        saveMarks(list, for: id)
    }

    /// The times to mark: every half second through the clip.
    static func checkpoints(_ clip: LabClip) -> [Double] {
        let count = max(1, Int(((clip.end - clip.start) / step).rounded(.down)) + 1)
        return (0..<count).map { clip.start + Double($0) * step }
    }
}

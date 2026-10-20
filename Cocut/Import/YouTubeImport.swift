import AppKit
import AVFoundation
import CryptoKit
import SwiftUI

/// Downloads a whole video from YouTube (or another site yt-dlp supports) in its original
/// quality, as one movie Cocut can use: for a full match, cleaner than recording the screen.
///
/// The download itself is done by yt-dlp, which Cocut fetches from its official GitHub release
/// on first use, checks against the release's published checksums, and refreshes weekly (sites
/// change and yt-dlp keeps up). YouTube serves 1080p video and its sound as separate files;
/// Cocut puts them together itself with AVFoundation, so nothing else needs installing.
@MainActor
@Observable
final class YouTubeImporter {
    enum State: Equatable {
        case idle
        /// Getting the downloader or looking the video up.
        case preparing(String)
        /// What's downloading, and how far along (nil while unknown).
        case downloading(String, Double?)
        case finished(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    private let runner = ProcessRunner()

    var isRunning: Bool {
        switch state {
        case .preparing, .downloading: return true
        default: return false
        }
    }

    /// Finished downloads: ~/Movies/Cocut/Downloads.
    static var downloadsFolder: URL {
        Platform.moviesRoot.appending(path: "Cocut/Downloads", directoryHint: .isDirectory)
    }

    func start(_ link: String) {
        guard !isRunning else { return }
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { await run(link) }
    }

    func cancel() {
        runner.terminate()
        task?.cancel()
        task = nil
        state = .idle
    }

    func reset() { state = .idle }

    private func run(_ link: String) async {
        let work = FileManager.default.temporaryDirectory.appending(path: "cocut-download-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            state = .preparing("Getting the downloader…")
            let tool = try await YTDLP.ensure()
            try Task.checkCancellation()

            state = .preparing("Looking up the video…")
            let info = try await runner.run(tool, ["--no-playlist", "--skip-download", "--print", "title", link])
            try Task.checkCancellation()
            guard info.status == 0 else { throw ImportError.download(Self.reason(from: info.output)) }
            // The title is the last line that isn't one of yt-dlp's own messages.
            let title = info.output.split(separator: "\n").map(String.init)
                .last { !$0.hasPrefix("WARNING") && !$0.hasPrefix("ERROR") && !$0.hasPrefix("[") }?
                .trimmingCharacters(in: .whitespaces) ?? "YouTube video"
            Log.info("YouTube import: \(title)")

            // H.264 video up to 1080p (what AVFoundation plays everywhere), then the sound.
            state = .downloading("Downloading the video…", 0)
            let video = try await download(tool, link, format: "bv*[ext=mp4][vcodec^=avc1][height<=1080]/bv*[ext=mp4][height<=1080]/b[ext=mp4]",
                                           to: work, name: "video", label: "Downloading the video…", range: 0...0.85)
            try Task.checkCancellation()
            var audio: URL?
            do {
                audio = try await download(tool, link, format: "ba[ext=m4a]/ba",
                                           to: work, name: "audio", label: "Downloading the sound…", range: 0.85...0.95)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A combined video file already has its sound; otherwise it comes in silent.
                Log.info("YouTube import: no separate sound (\(error.localizedDescription))")
            }
            try Task.checkCancellation()

            state = .downloading("Putting it together…", nil)
            try FileManager.default.createDirectory(at: Self.downloadsFolder, withIntermediateDirectories: true)
            let output = Self.uniqueURL(for: title)
            try await Self.merge(video: video, audio: audio, to: output)
            Log.info("YouTube import saved \(output.lastPathComponent)")
            state = .finished(output)
        } catch {
            // Cancelling stops yt-dlp, which then reports a failure: that's not one to show.
            if error is CancellationError || Task.isCancelled {
                state = .idle
            } else {
                Log.error("YouTube import failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// One yt-dlp download into `folder`, reporting its progress as part of `range`.
    private func download(_ tool: URL, _ link: String, format: String, to folder: URL, name: String,
                          label: String, range: ClosedRange<Double>) async throws -> URL {
        let template = folder.appending(path: "\(name).%(ext)s").path(percentEncoded: false)
        let result = try await runner.run(tool, ["--no-playlist", "--newline", "--no-part", "-f", format,
                                                 "-o", template, link]) { [weak self] line in
            guard let percent = Self.percent(in: line) else { return }
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(label, range.lowerBound + (range.upperBound - range.lowerBound) * percent)
            }
        }
        guard result.status == 0 else { throw ImportError.download(Self.reason(from: result.output)) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.deletingPathExtension().lastPathComponent == name }) else {
            throw ImportError.download("The download finished but no file was saved.")
        }
        return file
    }

    /// "[download]  42.3% of …" → 0.423.
    nonisolated static func percent(in line: String) -> Double? {
        guard line.hasPrefix("[download]"), let r = line.range(of: #"[0-9.]+(?=%)"#, options: .regularExpression),
              let value = Double(line[r]) else { return nil }
        return min(1, value / 100)
    }

    /// yt-dlp's own explanation ("ERROR: … Private video …"), or its last line.
    nonisolated static func reason(from output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        let error = lines.last { $0.hasPrefix("ERROR:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return error ?? lines.last ?? "The video couldn't be downloaded."
    }

    /// The video's own picture and the separate sound as one .mp4, without re-encoding.
    nonisolated static func merge(video: URL, audio: URL?, to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ImportError.download("The downloaded video has no picture Cocut can read.")
        }
        let duration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try picture?.insertTimeRange(range, of: videoTrack, at: .zero)
        picture?.preferredTransform = try await videoTrack.load(.preferredTransform)

        var soundTrack: AVAssetTrack?
        var soundDuration = duration
        if let audio {
            let audioAsset = AVURLAsset(url: audio)
            soundTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
            soundDuration = try await audioAsset.load(.duration)
        }
        if soundTrack == nil {
            soundTrack = try await videoAsset.loadTracks(withMediaType: .audio).first
        }
        if let soundTrack {
            let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try sound?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, soundDuration)),
                                       of: soundTrack, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ImportError.download("Cocut couldn't put the video and sound together.")
        }
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .mp4)
    }

    /// ~/Movies/Cocut/Downloads/<title>.mp4, numbered if taken.
    private static func uniqueURL(for title: String) -> URL {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = String((safe.isEmpty ? "YouTube video" : safe).prefix(80))
        var url = downloadsFolder.appending(path: "\(base).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = downloadsFolder.appending(path: "\(base) \(n).mp4")
            n += 1
        }
        return url
    }

    enum ImportError: LocalizedError {
        case download(String)
        case tool(String)

        var errorDescription: String? {
            switch self {
            case .download(let why): return why
            case .tool(let why): return "Cocut couldn't get the downloader. \(why)"
            }
        }
    }
}

/// yt-dlp, kept in ~/Library/Application Support/Cocut/Tools.
enum YTDLP {
    private static let release = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
    private static let asset = "yt-dlp_macos"
    /// How long a copy is used before checking for a newer one.
    private static let freshFor: TimeInterval = 7 * 24 * 3600

    static var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cocut/Tools/yt-dlp")
    }

    /// The tool, downloading or refreshing it when needed. A stale copy is still used if the
    /// refresh fails (offline, GitHub down).
    static func ensure() async throws -> URL {
        let fm = FileManager.default
        let path = location.path(percentEncoded: false)
        let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        if let modified, Date().timeIntervalSince(modified) < freshFor { return location }
        do {
            try await fetch()
        } catch {
            if fm.isExecutableFile(atPath: path) {
                Log.info("Couldn't refresh yt-dlp (\(error.localizedDescription)); using the copy Cocut has")
                return location
            }
            throw YouTubeImporter.ImportError.tool(error.localizedDescription)
        }
        return location
    }

    /// The latest release's macOS build, accepted only if it matches the release's SHA-256 list.
    private static func fetch() async throws {
        guard let binaryURL = URL(string: release + asset), let sumsURL = URL(string: release + "SHA2-256SUMS") else { return }
        let (sums, sumsResponse) = try await URLSession.shared.data(from: sumsURL)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200, let list = String(data: sums, encoding: .utf8),
              let expected = list.split(separator: "\n").first(where: { $0.hasSuffix(" \(asset)") })?
                .split(separator: " ").first.map({ String($0).lowercased() }) else {
            throw YouTubeImporter.ImportError.tool("The release's checksum list couldn't be read.")
        }
        let (download, response) = try await URLSession.shared.download(from: binaryURL)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw YouTubeImporter.ImportError.tool("GitHub didn't send the file.")
        }
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw YouTubeImporter.ImportError.tool("The downloaded file didn't match its published checksum, so it wasn't used.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = location.appendingPathExtension("new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: download, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path(percentEncoded: false))
        try? fm.removeItem(at: location)
        try fm.moveItem(at: staged, to: location)
        Log.info("Got yt-dlp (\(data.count / 1_000_000) MB, checksum verified)")
    }
}

/// Runs a command, handing each line of its output to `onLine` as it comes, and can stop it.
final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    struct Result { var status: Int32; var output: String }

    func run(_ tool: URL, _ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in collected.append(text) { onLine?(line) }
        }
        lock.withLock { self.process = process }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.withLock { self.process = nil }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { finished in
                    let rest = (try? pipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    for line in collected.append(rest + "\n") { onLine?(line) }
                    continuation.resume(returning: Result(status: finished.terminationStatus, output: collected.all))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    func terminate() {
        lock.withLock { process?.terminate() }
    }
}

/// Output gathered so far, split into whole lines as they complete.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var pending = ""

    /// Adds `chunk` and returns the lines it completed (progress lines end in a newline with --newline).
    func append(_ chunk: String) -> [String] {
        lock.withLock {
            text += chunk
            pending += chunk
            var lines = pending.components(separatedBy: CharacterSet.newlines)
            pending = lines.removeLast()
            return lines.filter { !$0.isEmpty }
        }
    }

    var all: String { lock.withLock { text } }
}

// MARK: - Window

/// What a downloaded video is, which decides where it goes.
enum YouTubeKind: String, CaseIterable, Identifiable {
    case match, clip
    var id: String { rawValue }
}

/// Import from YouTube: paste a link, say whether it's a full match or a clip, download.
/// A match opens Find Rallies; a clip goes into Clips.
struct YouTubeImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var importer = YouTubeImporter()
    @State private var link = ""
    @State private var kind: YouTubeKind = .match

    private var linkLooksRight: Bool {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()), url.host != nil else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l + 2) {
            HStack(alignment: .top, spacing: Design.Space.m) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Design.record)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("Import from YouTube").font(.title2.weight(.semibold))
                    Text("Downloads the whole video in its original quality: cleaner than recording the screen. Only for film you have the right to use, like your own uploads or your team's.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("Link", text: $link, prompt: Text("https://www.youtube.com/watch?v=…"))
                .textFieldStyle(.roundedBorder)
                .disabled(importer.isRunning)
                .onSubmit(start)

            Picker("It's", selection: $kind) {
                Text("A full match: open it in Find Rallies").tag(YouTubeKind.match)
                Text("A clip: add it to Clips").tag(YouTubeKind.clip)
            }
            .pickerStyle(.radioGroup)
            .disabled(importer.isRunning)

            status

            HStack {
                Text("Videos are kept in Movies › Cocut › Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    importer.cancel()
                    dismissWindow(id: "youtube")
                }
                .keyboardShortcut(.cancelAction)
                Button("Download") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!linkLooksRight || importer.isRunning)
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 540)
        .onAppear(perform: pasteLinkIfCopied)
        .onChange(of: importer.state) { _, state in
            if case .finished(let url) = state { use(url) }
        }
    }

    @ViewBuilder private var status: some View {
        switch importer.state {
        case .idle, .finished:
            EmptyView()
        case .preparing(let message):
            HStack(spacing: Design.Space.s) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .downloading(let message, let fraction):
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(fraction.map { "\(message) \(Int($0 * 100))%" } ?? message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .failed(let message):
            Banner(tone: .warning, icon: "exclamationmark.triangle.fill", title: "The download didn't work",
                   message: message) {
                Button("Show Log") { Log.reveal() }
            }
        }
    }

    private func start() {
        guard linkLooksRight, !importer.isRunning else { return }
        importer.start(link)
    }

    /// A link already on the clipboard fills the field, so it's paste-free.
    private func pasteLinkIfCopied() {
        guard link.isEmpty, let copied = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              copied.contains("youtube.com/") || copied.contains("youtu.be/") else { return }
        link = copied
    }

    private func use(_ file: URL) {
        dismissWindow(id: "youtube")
        switch kind {
        case .match:
            openWindow(id: "rallies")
            // Let the window come up before the court-marking sheet opens over it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.rallies.pendingMatch = file }
        case .clip:
            model.requestedSection = .clips
            openWindow(id: "main")
            Task {
                await model.importVideos([file])
                // Imports are copied into the project, so the download isn't needed twice.
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

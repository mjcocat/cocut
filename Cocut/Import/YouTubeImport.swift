import AppKit
import AVFoundation
import CryptoKit
import SwiftUI

/// Downloads a whole video from YouTube, Hudl (see `Hudl`) or another site yt-dlp supports, in its
/// original quality, as one movie Cocut can use: for a full match, cleaner than recording the screen.
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
        /// Saved, but at a lower resolution than the video is offered in (the file, what came
        /// through, what was expected): the user decides whether to use it.
        case lower(URL, got: Int, expected: Int)
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
    nonisolated static var downloadsFolder: URL {
        Platform.moviesRoot.appending(path: "Cocut/Downloads", directoryHint: .isDirectory)
    }

    /// Downloads `link`, or, for Hudl, the stream `hudl` found behind it.
    func start(_ link: String, hudl: Hudl.Video? = nil) {
        guard !isRunning else { return }
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { await run(hudl?.stream ?? link, hudl: hudl) }
    }

    /// Shown while a Hudl link is looked up, before the download starts.
    func lookingUp() { state = .preparing("Looking up the video on Hudl…") }

    func cancel() {
        runner.terminate()
        task?.cancel()
        task = nil
        state = .idle
    }

    func reset() { state = .idle }

    private func run(_ link: String, hudl: Hudl.Video?) async {
        let site = hudl != nil ? "Hudl" : "YouTube"
        let work = FileManager.default.temporaryDirectory.appending(path: "cocut-download-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            // Hudl streams come in pieces that only ffmpeg turns into a movie macOS can play
            // (a highlight's plain .mp4 file doesn't need it).
            if let hudl, hudl.stream.lowercased().contains(".m3u8"), Self.ffmpeg == nil {
                throw ImportError.download("Hudl videos need ffmpeg to put them together, and the one inside Cocut is missing. "
                                           + "Reinstall Cocut, or install ffmpeg (in Terminal: brew install ffmpeg), and try again.")
            }
            // A moment: just its few seconds of the video's stream, cut by ffmpeg itself.
            if let hudl, let section = hudl.section, let ffmpeg = Self.ffmpeg {
                let file = try await downloadSection(of: hudl, section, ffmpeg: ffmpeg, to: work)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: Self.downloadsFolder, withIntermediateDirectories: true)
                let output = Self.uniqueURL(for: hudl.title ?? "Hudl moment")
                try FileManager.default.moveItem(at: file, to: output)
                await finish(output, offered: nil)
                return
            }

            state = .preparing("Getting the downloader…")
            let tool = try await YTDLP.ensure()
            try Task.checkCancellation()

            // Hudl's streams expect to be played from Hudl, with the user's sign-in.
            var siteArguments: [String] = []
            if let hudl {
                siteArguments += ["--referer", "https://www.hudl.com/"]
                if !hudl.cookies.isEmpty {
                    let cookies = work.appending(path: "cookies.txt")
                    try Hudl.writeCookies(hudl.cookies, to: cookies)
                    siteArguments += ["--cookies", cookies.path(percentEncoded: false)]
                }
            }

            state = .preparing("Looking up the video…")
            // The title, and the tallest picture the video is offered in (any format).
            let info = try await runner.run(tool, ["--no-playlist", "--skip-download", "-f", "bv*/b",
                                                   "--print", "title", "--print", "%(height)s"] + siteArguments + [link])
            try Task.checkCancellation()
            guard info.status == 0 else { throw ImportError.download(Self.reason(from: info.output)) }
            // The last two lines that aren't yt-dlp's own messages.
            let printed = info.output.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("WARNING") && !$0.hasPrefix("ERROR") && !$0.hasPrefix("[") }
            let offered = printed.last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let title = hudl?.title ?? (offered != nil ? printed.dropLast().last : printed.last)?
                .trimmingCharacters(in: .whitespaces) ?? "\(site) video"
            Log.info("\(site) import: \(title), offered up to \(offered.map { "\($0)p" } ?? "unknown")")

            // H.264 video up to 1080p: what AVFoundation plays on every Mac. Never AV1 or VP9, which
            // older Macs can't play; the combined file (360p at most) only when nothing else exists.
            if let ffmpeg = Self.ffmpeg {
                // With ffmpeg (e.g. from Homebrew), yt-dlp puts picture and sound together itself:
                // more reliable than AVFoundation with some of YouTube's files.
                state = .downloading("Downloading…", 0)
                // Hudl's own streams may not say which codec they use; any up to 1080p then.
                let format = "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[vcodec^=avc1]" + (hudl != nil ? "/b[height<=1080]/b" : "")
                let extra = ["--merge-output-format", "mp4", "--ffmpeg-location", ffmpeg.path(percentEncoded: false)] + siteArguments
                var file: URL
                do {
                    file = try await download(tool, link, format: format, extra: extra,
                                              to: work, name: "video", label: "Downloading…", range: 0...0.95)
                } catch let error as ImportError where hudl != nil {
                    // Some Hudl film is several recordings in one stream, each starting with its own
                    // header ("Initialization fragment found after media fragments"), which yt-dlp's
                    // own downloader can't follow. ffmpeg can (it doesn't report a percentage).
                    Log.info("Hudl import: yt-dlp couldn't download the stream (\(error.localizedDescription)); trying with ffmpeg")
                    try Task.checkCancellation()
                    // What the first try left behind would be taken as already downloaded.
                    for leftover in (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
                    where leftover.lastPathComponent.hasPrefix("video.") {
                        try? FileManager.default.removeItem(at: leftover)
                    }
                    state = .downloading("Downloading with ffmpeg…", nil)
                    file = try await download(tool, link, format: format, extra: extra + ["--downloader", "m3u8:ffmpeg"],
                                              to: work, name: "video", label: "Downloading with ffmpeg…", range: 0...0.95)
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: Self.downloadsFolder, withIntermediateDirectories: true)
                let output = Self.uniqueURL(for: title)
                try FileManager.default.moveItem(at: file, to: output)
                Log.info("\(site) import: joined by yt-dlp with ffmpeg (\(ffmpeg.path(percentEncoded: false)))")
                await finish(output, offered: offered)
                return
            }
            state = .downloading("Downloading the video…", 0)
            let video = try await download(tool, link, format: "bv*[vcodec^=avc1][height<=1080]/b[vcodec^=avc1]"
                                               + (hudl != nil ? "/b[height<=1080]/b" : ""), extra: siteArguments,
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
            await finish(output, offered: offered)
        } catch {
            // Cancelling stops yt-dlp, which then reports a failure: that's not one to show.
            if error is CancellationError || Task.isCancelled {
                state = .idle
            } else {
                Log.error("\(site) import failed: \(Self.describe(error))")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Done: checks it got the quality it expected (1080p, or the video's best when it's posted lower).
    private func finish(_ output: URL, offered: Int?) async {
        let got = await Self.height(of: output)
        Log.info("YouTube import saved \(output.lastPathComponent) at \(got.map { "\($0)p" } ?? "unknown height")")
        if let got, let offered, got < min(offered, 1080) {
            state = .lower(output, got: got, expected: min(offered, 1080))
        } else {
            state = .finished(output)
        }
    }

    /// ffmpeg: the one inside Cocut (Contents/Helpers, built by scripts/build-ffmpeg.sh), or
    /// Homebrew's if that's missing. ffprobe sits next to it, where yt-dlp looks for it.
    static var ffmpeg: URL? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ffmpeg").path(percentEncoded: false)
        return [bundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Part of a Hudl stream (`section`, seconds into it) as one .mp4, without re-encoding.
    /// ffmpeg can't seek far into Hudl's streams made of several recordings, so Cocut writes a short
    /// playlist of just the segments around the part (`Hudl.trimmed`), at H.264 up to 1080p
    /// (`Hudl.variant`), and copies from the keyframe at or before its start, so nothing of the play
    /// is lost (Hudl's keyframes are a couple of seconds apart).
    private func downloadSection(of hudl: Hudl.Video, _ section: ClosedRange<Double>, ffmpeg: URL,
                                 to work: URL) async throws -> URL {
        state = .preparing("Finding the moment in the video…")
        let cookie = hudl.cookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: hudl.cookies)["Cookie"]
        func text(_ url: URL) async throws -> String {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("https://www.hudl.com/", forHTTPHeaderField: "Referer")
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
                throw ImportError.download("Hudl didn't send the video (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            return text
        }
        guard let master = URL(string: hudl.stream) else { throw ImportError.download("The Hudl video's link couldn't be read.") }
        let out = work.appending(path: "video.mp4")
        var input = master.absoluteString
        var offset = section.lowerBound
        /// Where the input starts in the stream: the first segment kept.
        var origin = 0.0
        if master.path.lowercased().hasSuffix(".m3u8") {
            var playlistURL = master
            var playlist = try await text(master)
            if let variant = Hudl.variant(in: playlist, base: master) {
                playlistURL = variant
                playlist = try await text(variant)
            }
            guard let cut = Hudl.trimmed(playlist, base: playlistURL, from: section.lowerBound, to: section.upperBound) else {
                throw ImportError.download("That moment isn't in the video Hudl sent.")
            }
            let list = work.appending(path: "moment.m3u8")
            try cut.text.write(to: list, atomically: true, encoding: .utf8)
            input = list.path(percentEncoded: false)
            origin = cut.start
            offset = section.lowerBound - cut.start
            Log.info("Hudl import: moment \(String(format: "%.1f–%.1f s", section.lowerBound, section.upperBound)) from "
                     + "\(playlistURL.lastPathComponent), \(cut.text.components(separatedBy: "#EXTINF").count - 1) segment(s)")
        }
        // Headers only for a link read directly: ffmpeg refuses them for a playlist file ("Option
        // headers not found"), and the segments in it, like Hudl's streams, need no sign-in.
        var reading = ["-protocol_whitelist", "file,http,https,tcp,tls,crypto"]
        if input.hasPrefix("http") {
            reading += ["-headers", "Referer: https://www.hudl.com/\r\n" + (cookie.map { "Cookie: \($0)\r\n" } ?? "")]
        }
        // Start on the keyframe at or before the moment (ffprobe sits next to ffmpeg).
        let ffprobe = ffmpeg.deletingLastPathComponent().appending(path: "ffprobe")
        if offset > 0, FileManager.default.isExecutableFile(atPath: ffprobe.path(percentEncoded: false)),
           let probe = try? await ProcessRunner().run(ffprobe, ["-v", "error"] + reading
               + ["-select_streams", "v:0", "-skip_frame", "nokey", "-show_entries", "frame=pts_time", "-of", "csv=p=0", input]),
           probe.status == 0 {
            let times = probe.output.split(whereSeparator: \.isNewline)
                .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
            if let first = times.min(), let key = times.map({ $0 - first }).filter({ $0 <= offset + 0.01 }).max() {
                offset = key
            }
        }
        let length = section.upperBound - origin - max(0, offset)
        state = .downloading("Downloading the moment…", nil)
        let result = try await runner.run(ffmpeg, ["-hide_banner", "-nostdin", "-y"] + reading
            + ["-i", input, "-ss", String(format: "%.3f", max(0, offset)), "-t", String(format: "%.3f", length),
               "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart", out.path(percentEncoded: false)]) { [weak self] line in
            guard let done = Self.ffmpegProgress(in: line) else { return }
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading("Downloading the moment… \(done)", nil)
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path(percentEncoded: false))[.size] as? Int) ?? 0
        guard result.status == 0, size > 0 else {
            let reason = result.output.split(separator: "\n").last.map(String.init) ?? "ffmpeg stopped."
            throw ImportError.download("The moment couldn't be downloaded. \(reason)")
        }
        Log.info("Hudl import: moment saved (\(size / 1000) KB)")
        return out
    }

    /// One yt-dlp download into `folder`, reporting its progress as part of `range`.
    private func download(_ tool: URL, _ link: String, format: String, extra: [String] = [], to folder: URL, name: String,
                          label: String, range: ClosedRange<Double>) async throws -> URL {
        let template = folder.appending(path: "\(name).%(ext)s").path(percentEncoded: false)
        let result = try await runner.run(tool, ["--no-playlist", "--newline", "--no-part", "-f", format]
                                                 + extra + ["-o", template, link]) { [weak self] line in
            if let done = Self.ffmpegProgress(in: line) {
                // ffmpeg downloading: how much of the video is in so far (it doesn't know the total).
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading("\(label) \(done)", nil)
                }
                return
            }
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

    /// The picture's upright height in pixels.
    nonisolated static func height(of file: URL) async -> Int? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        return Int(abs(CGRect(origin: .zero, size: size).applying(transform).height).rounded())
    }

    /// "[download]  42.3% of …" → 0.423.
    nonisolated static func percent(in line: String) -> Double? {
        guard line.hasPrefix("[download]"), let r = line.range(of: #"[0-9.]+(?=%)"#, options: .regularExpression),
              let value = Double(line[r]) else { return nil }
        return min(1, value / 100)
    }

    /// ffmpeg's progress line ("frame=… size=   18176KiB time=00:00:35.17 …") → "0:35 of video, 19 MB".
    nonisolated static func ffmpegProgress(in line: String) -> String? {
        guard let t = line.range(of: #"time=\d+:\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
        let parts = line[t].dropFirst(5).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let clock = parts[0] > 0 ? String(format: "%d:%02d:%02d", parts[0], parts[1], parts[2])
                                 : String(format: "%d:%02d", parts[1], parts[2])
        var text = "\(clock) of video"
        if let s = line.range(of: #"size=\s*\d+KiB"#, options: .regularExpression),
           let kib = Double(line[s].filter(\.isNumber)) {
            text += kib >= 1024 * 1024 ? String(format: ", %.1f GB", kib / 1024 / 1024) : String(format: ", %.0f MB", kib / 1024)
        }
        return text
    }

    /// yt-dlp's own explanation ("ERROR: … Private video …"), or its last line.
    nonisolated static func reason(from output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        let error = lines.last { $0.hasPrefix("ERROR:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return error ?? lines.last ?? "The video couldn't be downloaded."
    }

    /// The video's own picture and the separate sound as one .mp4, without re-encoding.
    nonisolated static func merge(video: URL, audio: URL?, to output: URL) async throws {
        do {
            try await join(video: video, audio: audio, to: output)
        } catch let error as ImportError {
            throw error
        } catch {
            // AVFoundation can't read some of YouTube's files at all (e.g. OSStatus -12780).
            Log.error("YouTube import: couldn't open the download: \(describe(error))")
            throw ImportError.download("macOS couldn't read the file YouTube sent, and the ffmpeg inside Cocut is missing. "
                                       + "Reinstall Cocut, or install ffmpeg (in Terminal: brew install ffmpeg), and try again.")
        }
    }

    private nonisolated static func join(video: URL, audio: URL?, to output: URL) async throws {
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
            // A sound file AVFoundation can't read (say, WebM) is left out rather than failing.
            let audioAsset = AVURLAsset(url: audio)
            do {
                soundTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
                soundDuration = try await audioAsset.load(.duration)
            } catch {
                Log.error("YouTube import: couldn't read the sound (\(audio.pathExtension)): \(Self.describe(error))")
            }
        }
        if soundTrack == nil {
            soundTrack = try await videoAsset.loadTracks(withMediaType: .audio).first
        }
        if let soundTrack {
            let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try sound?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, soundDuration)),
                                       of: soundTrack, at: .zero)
        }

        // As .mp4; if that's refused (a codec .mp4 can't hold), as .mov with the same name.
        var lastError: Error?
        for type in [AVFileType.mp4, .mov] {
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { continue }
            try? FileManager.default.removeItem(at: output)
            do {
                try await session.export(to: output, as: type)
                if type != .mp4 { Log.info("YouTube import: saved as QuickTime (.mp4 was refused)") }
                return
            } catch {
                lastError = error
                Log.error("YouTube import: putting it together as \(type == .mp4 ? "MP4" : "QuickTime") failed: \(Self.describe(error))"
                          + " (video \(video.pathExtension), sound \(audio?.pathExtension ?? "none"), \(Int(duration.seconds))s)")
            }
        }
        // Last resort: the downloaded video as it is, if it plays.
        if (try? await videoAsset.load(.isPlayable)) == true {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: video, to: output)
            Log.info("YouTube import: used the downloaded video as it is\(soundTrack == nil ? "" : " (its own sound only)")")
            return
        }
        throw ImportError.download("Cocut couldn't put the video and sound together. \(lastError?.localizedDescription ?? "")")
    }

    /// An error with its domain, code and underlying error, for the log (AVFoundation's own
    /// descriptions are often just "The operation could not be completed").
    nonisolated static func describe(_ error: Error) -> String {
        let e = error as NSError
        var text = "\(e.localizedDescription) [\(e.domain) \(e.code)]"
        if let reason = e.localizedFailureReason { text += " \(reason)" }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(under.domain) \(under.code) \(under.localizedDescription)"
        }
        return text
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

/// Import from YouTube or Hudl: paste a link, say whether it's a full match or a clip, download.
/// A match opens Find Rallies; a clip goes into Clips. Hudl team film opens a browser window to
/// sign in and find the video first (`HudlBrowser`).
struct YouTubeImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var importer = YouTubeImporter()
    @State private var link = ""
    @State private var kind: YouTubeKind = .match
    /// Chosen in the menu that opened the window, so the window doesn't ask again.
    @State private var chosenKind: YouTubeKind?
    /// The Hudl page to sign in on and find the video, while that window is up.
    @State private var hudlPage: String?

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
                    Text(chosenKind == .match ? "Import a Full Match" : chosenKind == .clip ? "Import a Clip" : "Import from YouTube or Hudl")
                        .font(.title2.weight(.semibold))
                    Text("Downloads the whole video in its original quality: cleaner than recording the screen. Only for film you have the right to use, like your own uploads or your team's.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("Link", text: $link, prompt: Text("A YouTube or Hudl link"))
                .textFieldStyle(.roundedBorder)
                .disabled(importer.isRunning)
                .onSubmit(start)

            if let chosenKind {
                Text(chosenKind == .match ? "From YouTube or Hudl. It opens in Find Rallies when it's downloaded."
                                          : "From YouTube or Hudl. It's added to Clips when it's downloaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("It's", selection: $kind) {
                    Text("A full match: open it in Find Rallies").tag(YouTubeKind.match)
                    Text("A clip: add it to Clips").tag(YouTubeKind.clip)
                }
                .pickerStyle(.radioGroup)
                .disabled(importer.isRunning)
            }

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
        .onAppear {
            takeChosenKind()
            pasteLinkIfCopied()
        }
        .onChange(of: model.importKind) { takeChosenKind() }
        .sheet(item: Binding(get: { hudlPage.map(HudlPage.init) }, set: { hudlPage = $0?.link })) { page in
            HudlBrowser(link: page.link) { video in
                hudlPage = nil
                // A moment is a few seconds: a clip, whatever the window was opened for.
                if video.section != nil { kind = .clip }
                importer.start(page.link, hudl: video)
            } onCancel: {
                hudlPage = nil
            }
        }
        .onChange(of: importer.state) { _, state in
            if case .finished(let url) = state { use(url) }
        }
    }

    @ViewBuilder private var status: some View {
        switch importer.state {
        case .idle, .finished:
            EmptyView()
        case .lower(let file, let got, let expected):
            Banner(tone: .warning, icon: "exclamationmark.triangle.fill", title: "Only \(got)p came through",
                   message: "The video is offered at \(expected)p, but the download was \(got)p. Trying again often gets the full quality.") {
                Button("Use \(got)p") { use(file) }
                Button("Try Again") {
                    try? FileManager.default.removeItem(at: file)
                    importer.reset()
                    start()
                }
                .buttonStyle(.borderedProminent)
            }
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
        guard linkLooksRight, !importer.isRunning, hudlPage == nil else { return }
        guard Hudl.isHudl(link) else { return importer.start(link) }
        // A public broadcast or a stream link downloads straight away; team film needs signing in.
        let page = link
        importer.lookingUp()
        Task {
            let video = await Hudl.direct(page)
            guard case .preparing = importer.state else { return }  // cancelled meanwhile
            if let video {
                importer.reset()
                importer.start(page, hudl: video)
            } else {
                importer.reset()
                hudlPage = page
            }
        }
    }

    /// Uses the kind the opening menu chose (the window may already be open).
    private func takeChosenKind() {
        guard let chosen = model.importKind, !importer.isRunning else { return }
        kind = chosen
        chosenKind = chosen
        model.importKind = nil
    }

    /// A link already on the clipboard fills the field, so it's paste-free.
    private func pasteLinkIfCopied() {
        guard link.isEmpty, let copied = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              copied.contains("youtube.com/") || copied.contains("youtu.be/") || Hudl.isHudl(copied) else { return }
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

/// A Hudl page for the sign-in sheet.
private struct HudlPage: Identifiable {
    let link: String
    var id: String { link }
}

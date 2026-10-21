import AppKit
import AVFoundation
import Foundation

/// Cocut Lab from Terminal (and for Claude Code). Run the app's executable with a command:
///
///     "/Applications/Cocut Lab.app/Contents/MacOS/Cocut Lab" status
///
/// (scripts/install-lab.sh also makes a `cocut-lab` command.)
@MainActor
enum LabCLI {
    static let commands: Set<String> = ["help", "--help", "-h", "status", "projects", "import-project", "add", "remove",
                                        "detect", "frames", "mark", "score", "tune", "settings", "--lab"]

    static let usage = """
    Cocut Lab: tune how Cocut's phone reels follow a player, on real clips.

    Usage: cocut-lab [--lab <folder>] <command> [options]

    The lab folder is ~/Documents/Cocut Lab unless --lab says otherwise.

    Commands:
      status                          Clips, what's been found and marked, and the score now.
      projects                        Cocut's projects, to import from.
      import-project <name> [--all] [--number N]
                                      Add a project's clips that have a spotlight (--all: every clip;
                                      clips without one are pointed out by their first head mark).
      add <video>... [--start S] [--end E] [--number N] [--group G]
                                      Add video files.
      remove <clip>... | --all        Remove clips from the lab (the videos stay).
      detect [--all] [<clip>...]      Find the people in clips (once per clip; --all redoes them).
      frames <clip> [--out <folder>] [--times t1,t2,...]
                                      Write a picture per checkpoint with everyone found numbered,
                                      the current guess in yellow and any mark in green.
      mark <clip> <time> head <x> <y> | box <n> | hidden | unsure | clear
                                      Mark where the player is at a checkpoint. x, y: 0...1 across
                                      and up from the bottom-left; box n: person n in that frame.
      score [--settings <file.json>]  Score settings (default: the ones built into this version).
      tune [--tries N] [--seed S] [--settings <file.json>]
                                      Search for better settings, checking them on clips held out
                                      from the search. Writes reports/ (Markdown and JSON).
      settings                        The built-in settings, as Swift and JSON.

    Clips are named by title or the start of their id (see status).
    """

    /// Runs `args` and exits.
    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            let code = await execute(args)
            exit(code)
        }
        dispatchMain()
    }

    static func execute(_ arguments: [String]) async -> Int32 {
        var args = arguments
        var folder = LabStore.defaultFolder
        if let i = args.firstIndex(of: "--lab"), i + 1 < args.count {
            folder = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
            args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first else { print(usage); return 0 }
        let rest = Array(args.dropFirst())
        var store = LabStore(folder: folder)
        do {
            switch command {
            case "help", "--help", "-h": print(usage)
            case "status": status(store)
            case "projects": try projects()
            case "import-project": try importProject(rest, store: &store)
            case "add": try await add(rest, store: &store)
            case "remove":
                guard !rest.isEmpty else { throw LabError.usage("remove <clip>... (or --all)") }
                let clips = try rest.contains("--all") ? store.clips : rest.map { key in
                    guard let clip = store.clip(key) else { throw LabError.noClip(key) }
                    return clip
                }
                for clip in clips { store.remove(clip.id) }
                store.save()
                print("Removed \(clips.count) clip\(clips.count == 1 ? "" : "s")")
            case "detect": try await detect(rest, store: store)
            case "frames": try await frames(rest, store: store)
            case "mark": try mark(rest, store: store)
            case "score": try score(rest, store: store)
            case "tune": try tune(rest, store: store)
            case "settings":
                print(LabTuner.swift(PlayerChain.Settings()))
                print(String(data: try JSONEncoder.pretty.encode(PlayerChain.Settings()), encoding: .utf8) ?? "")
            default:
                print("Unknown command “\(command)”.\n")
                print(usage)
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    enum LabError: LocalizedError {
        case noClip(String), noProject(String), usage(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noClip(let key): return "No clip “\(key)” in the lab (see status)."
            case .noProject(let key): return "No Cocut project “\(key)” (see projects)."
            case .usage(let text): return text
            case .unreadable(let what): return "Couldn't read \(what)."
            }
        }
    }

    // MARK: Options

    static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Arguments that aren't options or option values.
    static func positional(_ args: [String], options: Set<String>) -> [String] {
        var out: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if options.contains(a) { skip = true; continue }
            if a.hasPrefix("--") { continue }
            out.append(a)
        }
        return out
    }

    static func settings(_ args: [String]) throws -> PlayerChain.Settings {
        guard let path = option("--settings", in: args) else { return PlayerChain.Settings() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)),
              let s = try? JSONDecoder().decode(PlayerChain.Settings.self, from: data) else { throw LabError.unreadable(path) }
        return s
    }

    // MARK: Commands

    static func status(_ store: LabStore) {
        print("Lab: \(store.folder.path(percentEncoded: false))")
        print("Jersey number: \(store.index.number.map(String.init) ?? "not set (import a project, or add --number)")")
        if store.clips.isEmpty { print("No clips yet. Try: import-project <name>"); return }
        let cases = Dictionary(uniqueKeysWithValues: LabTuner.cases(store).map { ($0.clip.id, $0) })
        var total = (framed: 0, checked: 0)
        for clip in store.clips {
            let checkpoints = LabStore.checkpoints(clip).count
            let marks = store.marks(clip.id)
            var line = "\(clip.id.uuidString.prefix(8))  \(clip.title)  [\(clip.group)]  "
                + String(format: "%.1fs", clip.end - clip.start)
                + "  people: \(store.hasDetections(clip.id) ? "found" : "not yet")"
                + "  marked: \(marks.count)/\(checkpoints)"
                + (clip.spotlight == nil ? "  (no spotlight)" : "")
            if let c = cases[clip.id] {
                let s = LabTuner.score(c, settings: PlayerChain.Settings())
                total.framed += s.framed
                total.checked += s.checked
                line += "  in frame \(s.framed)/\(s.checked)"
            }
            print(line)
        }
        if total.checked > 0 {
            print(String(format: "Player in the phone frame: %d of %d marks (%.1f%%)", total.framed, total.checked,
                         100 * Double(total.framed) / Double(total.checked)))
        }
    }

    /// Cocut's projects (~/Movies/Cocut/projects.json).
    static func cocutProjects() throws -> [(project: Project, folder: URL)] {
        let root = Platform.moviesRoot.appending(path: "Cocut", directoryHint: .isDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: root.appending(path: "projects.json")),
              let list = try? decoder.decode([Project].self, from: data) else { throw LabError.unreadable("Cocut's projects") }
        return list.map { ($0, root.appending(path: "Projects/\($0.folder)", directoryHint: .isDirectory)) }
    }

    static func projects() throws {
        for (project, folder) in try cocutProjects() {
            let clips = (try? libraryClips(folder)) ?? []
            print("\(project.name)  (\(clips.count) clips, \(clips.filter { $0.spotlight != nil }.count) with a spotlight)")
        }
    }

    /// A project's clips, read straight from its library.json (Cocut's files aren't changed).
    static func libraryClips(_ folder: URL) throws -> [Clip] {
        struct File: Decodable { var items: [LibraryItem] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: folder.appending(path: "library.json"))
        if let file = try? decoder.decode(File.self, from: data) { return file.items.compactMap(\.clip) }
        return try decoder.decode([Clip].self, from: data)
    }

    static func importProject(_ args: [String], store: inout LabStore) throws {
        let all = args.contains("--all")
        guard let key = positional(args, options: ["--number"]).first else {
            throw LabError.usage("Which project? (see projects)")
        }
        let projects = try cocutProjects()
        guard let (project, folder) = projects.first(where: { $0.project.name.caseInsensitiveCompare(key) == .orderedSame })
                ?? projects.first(where: { $0.project.name.localizedCaseInsensitiveContains(key) }) else {
            throw LabError.noProject(key)
        }
        // The jersey number: --number, or the project's Player Card.
        var number = option("--number", in: args).flatMap { Int($0) }
        if number == nil,
           let data = try? Data(contentsOf: folder.appending(path: "profile.json")),
           let profile = try? JSONDecoder().decode(PlayerProfile.self, from: data) {
            number = Int(profile.featuredNumber.trimmingCharacters(in: .whitespaces))
        }
        if store.index.number == nil { store.index.number = number }
        var added = 0
        for clip in try libraryClips(folder) where all || clip.spotlight != nil {
            let url = folder.appending(path: "Clips/\(clip.fileName)")
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            let crop = clip.unitCrop
            let before = store.clips.count
            store.add(LabClip(id: UUID(), title: clip.title, video: url.path(percentEncoded: false),
                              start: clip.trimStartSeconds, end: clip.trimEndSeconds,
                              crop: crop.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
                              spotlight: clip.spotlight.map { [$0.x, $0.y, $0.radius] },
                              number: number == store.index.number ? nil : number, group: project.name))
            if store.clips.count > before { added += 1 }
        }
        store.save()
        print("Added \(added) clip\(added == 1 ? "" : "s") from \(project.name)" + (number.map { ", following #\($0)" } ?? ""))
    }

    static func add(_ args: [String], store: inout LabStore) async throws {
        let files = positional(args, options: ["--start", "--end", "--number", "--group"])
        guard !files.isEmpty else { throw LabError.usage("Which video files?") }
        let number = option("--number", in: args).flatMap { Int($0) }
        for path in files {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration > 0 else {
                throw LabError.unreadable(path)
            }
            let start = option("--start", in: args).flatMap { Double($0) } ?? 0
            let end = option("--end", in: args).flatMap { Double($0) } ?? duration
            store.add(LabClip(id: UUID(), title: url.deletingPathExtension().lastPathComponent, video: url.path(percentEncoded: false),
                              start: start, end: min(end, duration), crop: nil, spotlight: nil, number: number,
                              group: option("--group", in: args) ?? url.deletingPathExtension().lastPathComponent))
            print("Added \(url.lastPathComponent). With no spotlight, its first head mark points out the player.")
        }
        store.save()
    }

    static func detect(_ args: [String], store: LabStore) async throws {
        let redo = args.contains("--all")
        let keys = positional(args, options: [])
        let clips = try keys.isEmpty ? store.clips : keys.map { key in
            guard let c = store.clip(key) else { throw LabError.noClip(key) }
            return c
        }
        let todo = clips.filter { redo || !keys.isEmpty || !store.hasDetections($0.id) }
        if todo.isEmpty { print("People already found in every clip (detect --all redoes them)."); return }
        for (n, clip) in todo.enumerated() {
            let started = Date()
            print("[\(n + 1)/\(todo.count)] \(clip.title)…", terminator: "")
            fflush(stdout)
            guard let found = try await PlayerTracker.detect(url: clip.videoURL, start: clip.start, end: clip.end,
                                                             unitCrop: clip.unitCrop) else {
                print(" couldn't read the video")
                continue
            }
            store.saveDetections(found, for: clip.id)
            let people = Double(found.frames.map(\.people.count).reduce(0, +)) / Double(max(1, found.frames.count))
            print(String(format: " %d frames, %.1f people a frame, %.0fs", found.frames.count, people, Date().timeIntervalSince(started)))
        }
    }

    static func mark(_ args: [String], store: LabStore) throws {
        guard args.count >= 3, let clip = store.clip(args[0]), let time = Double(args[1]) else {
            throw LabError.usage("mark <clip> <time> head <x> <y> | box <n> | hidden | unsure | clear")
        }
        let t = LabStore.checkpoints(clip).min { abs($0 - time) < abs($1 - time) } ?? time
        switch args[2] {
        case "head":
            guard args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) else { throw LabError.usage("head <x> <y>") }
            store.setMark(.head(t, x, y), at: t, for: clip.id)
        case "box":
            guard args.count >= 4, let n = Int(args[3]), let d = store.detections(clip.id),
                  let frame = d.frames.min(by: { abs($0.time - t) < abs($1.time - t) }), frame.people.indices.contains(n) else {
                throw LabError.usage("box <n>: a person numbered in that checkpoint's picture (run frames first)")
            }
            let p = frame.people[n]
            store.setMark(.head(t, p.head.x, p.head.y), at: t, for: clip.id)
        case "hidden": store.setMark(LabMark(time: t, kind: .hidden), at: t, for: clip.id)
        case "unsure": store.setMark(LabMark(time: t, kind: .unsure), at: t, for: clip.id)
        case "clear": store.setMark(nil, at: t, for: clip.id)
        default: throw LabError.usage("mark <clip> <time> head <x> <y> | box <n> | hidden | unsure | clear")
        }
        print(String(format: "%@ at %.1fs: %@", clip.title, t, args[2]))
    }

    static func score(_ args: [String], store: LabStore) throws {
        let s = try settings(args)
        let cases = LabTuner.cases(store)
        guard !cases.isEmpty else { print("Nothing to score: clips need people found (detect) and at least 3 marks."); return }
        var f = 0, c = 0
        for k in cases {
            let r = LabTuner.score(k, settings: s)
            f += r.framed
            c += r.checked
            print("\(r.title) [\(r.group)]: in frame \(r.framed)/\(r.checked), right player \(r.right), wrong \(r.wrong), gaps \(r.gaps)")
        }
        print(String(format: "In the phone frame: %d of %d (%.1f%%). Score %.1f%%", f, c, 100 * Double(f) / Double(max(1, c)),
                     100 * LabTuner.value(cases, settings: s)))
    }

    static func tune(_ args: [String], store: LabStore) throws {
        let cases = LabTuner.cases(store)
        guard cases.count >= 2 else {
            print("Tuning needs at least 2 clips with people found and marks (have \(cases.count)).")
            return
        }
        let tries = option("--tries", in: args).flatMap { Int($0) } ?? 600
        let seed = option("--seed", in: args).flatMap { UInt64($0) } ?? 1
        let report = LabTuner.tune(cases, baseline: try settings(args), tries: tries, seed: seed) { print($0) }
        let stamp = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
        let reports = store.folder.appending(path: "reports", directoryHint: .isDirectory)
        let markdown = LabTuner.markdown(report)
        try markdown.write(to: reports.appending(path: "tune-\(stamp).md"), atomically: true, encoding: .utf8)
        try JSONEncoder.pretty.encode(report).write(to: reports.appending(path: "tune-\(stamp).json"))
        try JSONEncoder.pretty.encode(report.tuned).write(to: reports.appending(path: "latest-settings.json"))
        print("")
        print(markdown)
        print("Saved reports/tune-\(stamp).md and reports/latest-settings.json")
    }

    // MARK: Pictures

    static func frames(_ args: [String], store: LabStore) async throws {
        guard let key = positional(args, options: ["--out", "--times"]).first, let clip = store.clip(key) else {
            throw LabError.noClip(args.first ?? "")
        }
        let out = option("--out", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? store.folder.appending(path: "frames/\(clip.id.uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let times = option("--times", in: args)?.split(separator: ",").compactMap { Double($0) } ?? LabStore.checkpoints(clip)
        let detections = store.detections(clip.id)
        let guess = LabPictures.guess(store: store, clip: clip)
        let marks = store.marks(clip.id)
        for t in times {
            guard let image = await LabPictures.frame(clip: clip, at: t) else { continue }
            let frame = detections?.frames.min { abs($0.time - t) < abs($1.time - t) }
            let png = LabPictures.annotated(image, people: frame?.people ?? [], guess: frame.flatMap { f in guess?[f.time] },
                                            mark: marks.first { abs($0.time - t) < 0.01 }, caption: String(format: "%@  %.1fs", clip.title, t))
            try png.write(to: out.appending(path: String(format: "%07.2f.png", t)))
        }
        print("Wrote \(times.count) pictures to \(out.path(percentEncoded: false))")
        print("People are numbered in each picture: mark with “mark \(clip.title) <time> box <n>”.")
    }
}

/// Frames of a clip and pictures of them, for the labeling window and `frames`.
@MainActor
enum LabPictures {
    /// The upright frame at `time` (the whole frame; any crop is drawn over it).
    static func frame(clip: LabClip, at time: Double, maxWidth: CGFloat = 1600) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// The current settings' guess: the followed person, by frame time.
    static func guess(store: LabStore, clip: LabClip, settings: PlayerChain.Settings = PlayerChain.Settings()) -> [Double: PlayerChain.Person]? {
        guard let d = store.detections(clip.id) else { return nil }
        var anchors: [PlayerChain.Anchor] = []
        if let s = clip.spotlight, s.count >= 2 {
            let crop = clip.unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            anchors.append(.init(time: clip.start, x: Double(crop.minX) + s[0] * Double(crop.width),
                                 y: 1 - (Double(crop.minY) + s[1] * Double(crop.height)), kind: .body))
        } else if let first = store.marks(clip.id).first(where: { $0.kind == .head }), let x = first.x, let y = first.y {
            anchors.append(.init(time: first.time, x: x, y: y, kind: .head))
        }
        guard !anchors.isEmpty else { return nil }
        let path = PlayerChain.follow(d.frames, anchors: anchors, number: store.number(for: clip), aspect: d.aspect, settings: settings)
        var out: [Double: PlayerChain.Person] = [:]
        for (f, p) in zip(d.frames, path) { if let p { out[f.time] = p } }
        return out
    }

    /// A PNG of `image` with everyone found numbered (grey), the guess (yellow) and the mark (green).
    static func annotated(_ image: CGImage, people: [PlayerChain.Person], guess: PlayerChain.Person?, mark: LabMark?,
                          caption: String) -> Data {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Vision coordinates have the origin bottom-left, like this context.
        func rect(_ p: PlayerChain.Person) -> CGRect { CGRect(x: p.x * w, y: p.y * h, width: p.width * w, height: p.height * h) }
        let font = NSFont.boldSystemFont(ofSize: max(14, h / 40))
        for (i, p) in people.enumerated() {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(max(1.5, h / 600))
            ctx.stroke(rect(p))
            let label = NSAttributedString(string: " \(i) ", attributes: [
                .font: font, .foregroundColor: NSColor.black, .backgroundColor: NSColor.white.withAlphaComponent(0.85)])
            label.draw(at: CGPoint(x: rect(p).minX, y: rect(p).maxY - label.size().height))
        }
        if let guess {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(max(3, h / 250))
            ctx.stroke(rect(guess).insetBy(dx: -3, dy: -3))
        }
        if let mark, mark.kind == .head, let x = mark.x, let y = mark.y {
            let r = max(8, h / 60)
            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(max(3, h / 250))
            ctx.strokeEllipse(in: CGRect(x: x * w - r, y: y * h - r, width: r * 2, height: r * 2))
        }
        let title = NSAttributedString(string: " \(caption)\(mark.map { "  ·  marked \($0.kind.rawValue)" } ?? "") ", attributes: [
            .font: font, .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)])
        title.draw(at: CGPoint(x: 8, y: h - title.size().height - 8))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

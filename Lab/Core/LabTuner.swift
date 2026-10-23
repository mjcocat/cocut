import Foundation

/// Scores PlayerChain settings against hand-marked clips, and searches for better ones without
/// fooling itself: settings are tuned on some clips and judged on others they never saw.
enum LabTuner {
    /// One clip ready to score: what was found in it, the marks, and where the player was pointed out.
    struct Case {
        var clip: LabClip
        var detections: ClipDetections
        var marks: [LabMark]
        var anchors: [PlayerChain.Anchor]
        var number: Int?
        /// Marks scored (the first head mark is left out when it's what pointed the player out).
        var scored: [LabMark]
    }

    struct ClipScore: Codable {
        var title: String
        var group: String
        /// Marks with the player's head.
        var checked = 0
        /// The head inside the phone frame.
        var framed = 0
        /// The followed box is the player / someone else / nobody.
        var right = 0
        var wrong = 0
        var gaps = 0

        var framedRate: Double { checked == 0 ? 0 : Double(framed) / Double(checked) }
        /// What tuning maximizes (0...1): in the frame, and following the right person rather than
        /// the wrong one.
        var value: Double {
            checked == 0 ? 0 : max(0, (Double(framed) + 0.5 * Double(right - wrong)) / (1.5 * Double(checked)))
        }
    }

    /// The cases from a lab: clips with detections, at least a few marks, and a way to point the
    /// player out (a spotlight, or a first head mark).
    static func cases(_ store: LabStore, detections load: ((UUID) -> ClipDetections?)? = nil) -> [Case] {
        store.clips.compactMap { clip in
            guard let detections = load?(clip.id) ?? store.detections(clip.id) else { return nil }
            let marks = store.marks(clip.id)
            var anchors: [PlayerChain.Anchor] = []
            var scored = marks.filter { $0.kind == .head }
            if let s = clip.spotlight, s.count >= 2 {
                let crop = clip.unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                anchors.append(.init(time: clip.spotlightTime, x: Double(crop.minX) + s[0] * Double(crop.width),
                                     y: 1 - (Double(crop.minY) + s[1] * Double(crop.height)), kind: .body))
            } else if let first = scored.first, let x = first.x, let y = first.y {
                anchors.append(.init(time: first.time, x: x, y: y, kind: .head))
                scored.removeFirst()
            }
            guard !anchors.isEmpty, scored.count >= 3 else { return nil }
            return Case(clip: clip, detections: detections, marks: marks, anchors: anchors,
                        number: store.number(for: clip), scored: scored)
        }
    }

    // MARK: Scoring

    /// Follows the player in `c` with `settings` and scores it against the marks.
    static func score(_ c: Case, settings: PlayerChain.Settings) -> ClipScore {
        let path = PlayerChain.follow(c.detections.frames, anchors: c.anchors, number: c.number,
                                      aspect: c.detections.aspect, settings: settings)
        return score(c, path: path)
    }

    /// Scores a followed path against the marks.
    static func score(_ c: Case, path: [PlayerChain.Person?]) -> ClipScore {
        let d = c.detections
        let crop = d.unitCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        func picture(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            ((x - Double(crop.minX)) / max(0.0001, Double(crop.width)), ((1 - y) - Double(crop.minY)) / max(0.0001, Double(crop.height)))
        }
        let sightings = zip(d.frames, path).compactMap { frame, p -> CameraPlanner.Sighting? in
            guard let p else { return nil }
            let q = picture(p.center.x, p.center.y)
            return .init(time: frame.time, x: q.x, y: q.y)
        }
        let window = CameraPlanner.window(picture: (d.width * Double(crop.width), d.height * Double(crop.height)),
                                          output: (1080, 1920))
        let camera = CameraPlanner.plan(sightings: sightings, start: d.start, end: d.end, window: window)

        var s = ClipScore(title: c.clip.title, group: c.clip.group)
        let times = d.frames.map(\.time)
        for mark in c.scored {
            guard let x = mark.x, let y = mark.y, !times.isEmpty else { continue }
            s.checked += 1
            // In the phone frame (with a little room around the head).
            let head = picture(x, y)
            let cam = camera.center(at: mark.time)
            let inX = abs(head.x - cam.x) <= window.width / 2 - 0.02
            let inY = window.height >= 0.999 || abs(head.y - cam.y) <= window.height / 2 - 0.02
            if inX && inY { s.framed += 1 }
            // The box followed at that moment.
            let k = times.indices.min { abs(times[$0] - mark.time) < abs(times[$1] - mark.time) }!
            if let p = path[k] {
                let hit = abs(p.head.x - x) < max(0.04, p.width * 0.6) && (p.head.y - y) > -p.height * 0.25 && (p.head.y - y) < p.height * 0.45
                if hit { s.right += 1 } else { s.wrong += 1 }
            } else {
                s.gaps += 1
            }
        }
        return s
    }

    /// Mean value over clips (each clip counts the same, however long).
    static func value(_ cases: [Case], settings: PlayerChain.Settings) -> Double {
        guard !cases.isEmpty else { return 0 }
        var values = [Double](repeating: 0, count: cases.count)
        values.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: cases.count) { i in
                out[i] = score(cases[i], settings: settings).value
            }
        }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: Search

    /// A setting the search may change, and its range.
    struct Knob {
        var name: String
        var range: ClosedRange<Double>
        var integer = false
        var get: (PlayerChain.Settings) -> Double
        var set: (inout PlayerChain.Settings, Double) -> Void
    }

    static let knobs: [Knob] = [
        Knob(name: "perFrame", range: 0.2...2, get: { $0.perFrame }, set: { $0.perFrame = $1 }),
        Knob(name: "distanceCost", range: 1...12, get: { $0.distanceCost }, set: { $0.distanceCost = $1 }),
        Knob(name: "sizeCost", range: 1...14, get: { $0.sizeCost }, set: { $0.sizeCost = $1 }),
        Knob(name: "gapCost", range: 0...6, get: { $0.gapCost }, set: { $0.gapCost = $1 }),
        Knob(name: "reach", range: 0.15...0.9, get: { $0.reach }, set: { $0.reach = $1 }),
        Knob(name: "reachPerSecond", range: 0.3...3, get: { $0.reachPerSecond }, set: { $0.reachPerSecond = $1 }),
        Knob(name: "joinCost", range: 0.3...1.0, get: { $0.joinCost }, set: { $0.joinCost = $1 }),
        Knob(name: "joinSize", range: 0.2...0.7, get: { $0.joinSize }, set: { $0.joinSize = $1 }),
        Knob(name: "excludeAt", range: 2...12, integer: true, get: { $0.excludeAt }, set: { $0.excludeAt = $1 }),
        Knob(name: "otherCost", range: 0...12, get: { $0.otherCost }, set: { $0.otherCost = $1 }),
        Knob(name: "chunkFrames", range: 0...60, integer: true, get: { Double($0.chunkFrames) }, set: { $0.chunkFrames = Int($1) }),
    ]

    /// A small, seeded random number generator, so a search can be repeated exactly.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
            return z ^ (z >> 33)
        }
    }

    /// The best settings found for `cases`: random tries around the whole range, then nudging
    /// one knob at a time from the best. Starts from (and never does worse than) `start`.
    static func search(_ cases: [Case], start: PlayerChain.Settings, tries: Int, rng: inout Random,
                       progress: ((Int, Double) -> Void)? = nil) -> (settings: PlayerChain.Settings, value: Double) {
        var best = start
        var bestValue = value(cases, settings: start)
        var done = 0
        func consider(_ s: PlayerChain.Settings) {
            let v = value(cases, settings: s)
            done += 1
            if v > bestValue + 1e-9 { best = s; bestValue = v }
            progress?(done, bestValue)
        }
        let randomTries = tries * 2 / 3
        for _ in 0..<randomTries {
            var s = best
            // Change a few knobs at once, anywhere in their range.
            for knob in knobs.shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng)) {
                var v = Double.random(in: knob.range, using: &rng)
                if knob.integer { v = v.rounded() }
                knob.set(&s, v)
            }
            consider(s)
        }
        // Nudge one knob at a time, in shrinking steps.
        var scale = 0.25
        var left = tries - randomTries
        while left > 0 {
            var improved = false
            for knob in knobs where left > 0 {
                for direction in [-1.0, 1.0] where left > 0 {
                    var s = best
                    let width = knob.range.upperBound - knob.range.lowerBound
                    var v = min(knob.range.upperBound, max(knob.range.lowerBound, knob.get(best) + direction * scale * width))
                    if knob.integer { v = v.rounded() }
                    knob.set(&s, v)
                    let before = bestValue
                    consider(s)
                    left -= 1
                    if bestValue > before { improved = true }
                }
            }
            if !improved { scale /= 2 }
            if scale < 0.01 { break }
        }
        return (best, bestValue)
    }

    // MARK: Report

    struct Report: Codable {
        struct Fold: Codable {
            var heldOut: String
            var baseline: Double
            var tuned: Double
        }
        var date: Date
        var clips: Int
        var groups: Int
        var marks: Int
        var baseline: PlayerChain.Settings
        var tuned: PlayerChain.Settings
        /// On every clip.
        var baselineValue: Double
        var tunedValue: Double
        var baselineScores: [ClipScore]
        var tunedScores: [ClipScore]
        /// Tuned without the held-out clips, judged on them.
        var folds: [Fold]
        var heldOutBaseline: Double
        var heldOutTuned: Double

        /// Worth adopting: better on clips it wasn't tuned on, and no held-out group much worse.
        var recommended: Bool {
            heldOutTuned >= heldOutBaseline + 0.02 && !folds.contains { $0.tuned < $0.baseline - 0.05 }
        }
    }

    /// Tunes on all clips, and checks the tuning on clips held out from it: by group when there
    /// are at least two groups (each match held out in turn), otherwise in five folds of clips.
    static func tune(_ cases: [Case], baseline: PlayerChain.Settings, tries: Int, seed: UInt64,
                     log: @escaping (String) -> Void) -> Report {
        var rng = Random(state: seed)
        let groups = Array(Set(cases.map(\.clip.group))).sorted()
        var folds: [(name: String, held: [Int])] = []
        if groups.count >= 2 {
            folds = groups.map { g in (g, cases.indices.filter { cases[$0].clip.group == g }) }
        } else if cases.count >= 4 {
            let k = min(5, cases.count)
            let order = Array(cases.indices).shuffled(using: &rng)
            folds = (0..<k).map { f in ("fold \(f + 1)", order.enumerated().filter { $0.offset % k == f }.map(\.element)) }
        }

        var foldResults: [Report.Fold] = []
        for (n, fold) in folds.enumerated() {
            let held = Set(fold.held)
            let train = cases.indices.filter { !held.contains($0) }.map { cases[$0] }
            let test = fold.held.map { cases[$0] }
            guard !train.isEmpty, !test.isEmpty else { continue }
            log("Checking: tuning without \(fold.name) (\(n + 1) of \(folds.count))…")
            let found = search(train, start: baseline, tries: tries, rng: &rng)
            let result = Report.Fold(heldOut: fold.name, baseline: value(test, settings: baseline),
                                     tuned: value(test, settings: found.settings))
            log(String(format: "  %@: %.1f%% → %.1f%%", fold.name, result.baseline * 100, result.tuned * 100))
            foldResults.append(result)
        }

        log("Tuning on all \(cases.count) clips…")
        let final = search(cases, start: baseline, tries: tries, rng: &rng) { done, best in
            if done % 100 == 0 { log(String(format: "  %d tries, best %.1f%%", done, best * 100)) }
        }
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        return Report(date: Date(), clips: cases.count, groups: groups.count,
                      marks: cases.map(\.scored.count).reduce(0, +),
                      baseline: baseline, tuned: final.settings,
                      baselineValue: value(cases, settings: baseline), tunedValue: final.value,
                      baselineScores: cases.map { score($0, settings: baseline) },
                      tunedScores: cases.map { score($0, settings: final.settings) },
                      folds: foldResults,
                      heldOutBaseline: mean(foldResults.map(\.baseline)), heldOutTuned: mean(foldResults.map(\.tuned)))
    }

    /// The report as Markdown, with the settings as Swift to paste into PlayerChain.Settings.
    static func markdown(_ r: Report) -> String {
        func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
        func framed(_ scores: [ClipScore]) -> String {
            let f = scores.map(\.framed).reduce(0, +), c = scores.map(\.checked).reduce(0, +)
            return "\(f) of \(c) (\(pct(c == 0 ? 0 : Double(f) / Double(c))))"
        }
        var lines: [String] = []
        lines.append("# Phone follow tuning")
        lines.append("")
        lines.append("\(r.clips) clips in \(r.groups) group\(r.groups == 1 ? "" : "s"), \(r.marks) marks. \(ISO8601DateFormatter().string(from: r.date))")
        lines.append("")
        lines.append("## Verdict")
        lines.append("")
        if r.folds.isEmpty {
            lines.append("Not enough clips to check the tuning on clips it didn't see. Add more clips (ideally from more than one match).")
        } else {
            lines.append("On clips held out from tuning: **\(pct(r.heldOutBaseline)) → \(pct(r.heldOutTuned))**.")
            lines.append(r.recommended
                         ? "**Recommended:** the tuned settings do better on clips they weren't tuned on."
                         : "**Not recommended:** the gain doesn't hold up on clips the tuning didn't see (or a held-out group got worse).")
        }
        lines.append("")
        lines.append("## Player in the phone frame")
        lines.append("")
        lines.append("- Current settings: \(framed(r.baselineScores)), score \(pct(r.baselineValue))")
        lines.append("- Tuned settings: \(framed(r.tunedScores)), score \(pct(r.tunedValue))")
        lines.append("")
        if !r.folds.isEmpty {
            lines.append("## Held out")
            lines.append("")
            lines.append("| Held out | Current | Tuned without it |")
            lines.append("|---|---|---|")
            for f in r.folds { lines.append("| \(f.heldOut) | \(pct(f.baseline)) | \(pct(f.tuned)) |") }
            lines.append("")
        }
        lines.append("## Clips")
        lines.append("")
        lines.append("| Clip | Group | Marks | In frame now | In frame tuned | Wrong player now → tuned |")
        lines.append("|---|---|---|---|---|---|")
        for (a, b) in zip(r.baselineScores, r.tunedScores) {
            lines.append("| \(a.title) | \(a.group) | \(a.checked) | \(a.framed) | \(b.framed) | \(a.wrong) → \(b.wrong) |")
        }
        lines.append("")
        lines.append("## Settings")
        lines.append("")
        lines.append("Paste into `PlayerChain.Settings` in Shared/Export/PlayerChain.swift:")
        lines.append("")
        lines.append("```swift")
        lines.append(swift(r.tuned))
        lines.append("```")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Settings as the defaults in PlayerChain.Settings.
    static func swift(_ s: PlayerChain.Settings) -> String {
        func f(_ v: Double) -> String { String(format: "%.3g", v).contains(".") || String(format: "%.3g", v).contains("e") ? String(format: "%.3g", v) : String(format: "%.3g", v) + ".0" }
        return [
            "var perFrame = \(f(s.perFrame))",
            "var distanceCost = \(f(s.distanceCost))",
            "var sizeCost = \(f(s.sizeCost))",
            "var gapCost = \(f(s.gapCost))",
            "var reach = \(f(s.reach))",
            "var reachPerSecond = \(f(s.reachPerSecond))",
            "var joinCost = \(f(s.joinCost))",
            "var joinSize = \(f(s.joinSize))",
            "var chunkFrames = \(s.chunkFrames)",
            "var excludeAt = \(f(s.excludeAt))",
            "var otherCost = \(f(s.otherCost))",
            "var lookWeight = \(f(s.lookWeight))",
        ].joined(separator: "\n")
    }
}

import Foundation

/// How well Find Rallies' rallies match the ones you settled on (after adding, removing and
/// retiming them). The usual measure for this (as in SetOptics): pair each found rally with a
/// real one when they overlap enough (intersection over union at least 0.5), then precision
/// (found rallies that are real), recall (real rallies found), and F1 (the two together).
enum RallyScore {
    struct Segment: Codable, Hashable {
        var start: Double
        var end: Double
        var duration: Double { max(0, end - start) }
    }

    struct Result: Codable {
        var name: String
        var found: Int
        var real: Int
        var matched: Int
        /// Mean start and end error of matched rallies (seconds; negative is early).
        var startError: Double
        var endError: Double
        /// Real rallies under 6 seconds, and how many were found (short rallies are the hard ones).
        var short: Int
        var shortMatched: Int
        /// Real rallies not found, and found rallies that aren't real (start times), for looking at.
        var missed: [Double]
        var extra: [Double]

        var precision: Double { found == 0 ? 0 : Double(matched) / Double(found) }
        var recall: Double { real == 0 ? 0 : Double(matched) / Double(real) }
        var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
    }

    static func iou(_ a: Segment, _ b: Segment) -> Double {
        let inter = max(0, min(a.end, b.end) - max(a.start, b.start))
        let union = a.duration + b.duration - inter
        return union > 0 ? inter / union : 0
    }

    /// Pairs found and real rallies, best overlap first, each used once.
    static func score(name: String, found: [Segment], real: [Segment], threshold: Double = 0.5) -> Result {
        var pairs: [(Double, Int, Int)] = []
        for (i, f) in found.enumerated() {
            for (j, r) in real.enumerated() {
                let o = iou(f, r)
                if o >= threshold { pairs.append((o, i, j)) }
            }
        }
        pairs.sort { $0.0 > $1.0 }
        var usedFound = Set<Int>(), usedReal = Set<Int>()
        var startErrors: [Double] = [], endErrors: [Double] = []
        for (_, i, j) in pairs where !usedFound.contains(i) && !usedReal.contains(j) {
            usedFound.insert(i)
            usedReal.insert(j)
            startErrors.append(found[i].start - real[j].start)
            endErrors.append(found[i].end - real[j].end)
        }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let short = real.indices.filter { real[$0].duration < 6 }
        return Result(name: name, found: found.count, real: real.count, matched: usedFound.count,
                      startError: mean(startErrors), endError: mean(endErrors),
                      short: short.count, shortMatched: short.filter(usedReal.contains).count,
                      missed: real.indices.filter { !usedReal.contains($0) }.map { real[$0].start },
                      extra: found.indices.filter { !usedFound.contains($0) }.map { found[$0].start })
    }

    /// All matches together (rallies pooled, so long matches count for more).
    static func total(_ results: [Result]) -> Result {
        func sum(_ k: KeyPath<Result, Int>) -> Int { results.map { $0[keyPath: k] }.reduce(0, +) }
        let matched = sum(\.matched)
        func weighted(_ k: KeyPath<Result, Double>) -> Double {
            matched == 0 ? 0 : results.map { $0[keyPath: k] * Double($0.matched) }.reduce(0, +) / Double(matched)
        }
        return Result(name: "All", found: sum(\.found), real: sum(\.real), matched: matched,
                      startError: weighted(\.startError), endError: weighted(\.endError),
                      short: sum(\.short), shortMatched: sum(\.shortMatched), missed: [], extra: [])
    }

    static func markdown(_ results: [Result], skipped: [String]) -> String {
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        func sec(_ v: Double) -> String { String(format: "%+.1fs", v) }
        func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        var lines = ["# Find Rallies accuracy", ""]
        guard !results.isEmpty else {
            lines.append("No matches to score yet: score uses matches where you changed the rallies in Find Rallies "
                         + "(added, removed, unticked or retimed one), and whose video is still on this Mac.")
            return lines.joined(separator: "\n") + "\n"
        }
        let all = total(results)
        lines.append("Found rallies scored against the rallies you settled on in Find Rallies, on \(results.count) "
                     + "match\(results.count == 1 ? "" : "es"). A found rally counts when it overlaps a real one by at least half "
                     + "(intersection over union 0.5).")
        lines.append("")
        lines.append("**F1 \(pct(all.f1))**: \(all.matched) of \(all.real) real rallies found (recall \(pct(all.recall))), "
                     + "\(all.found - all.matched) of \(all.found) found weren't real (precision \(pct(all.precision))). "
                     + "Short rallies (under 6s): \(all.shortMatched) of \(all.short) found. "
                     + "Matched rallies start \(sec(all.startError)) and end \(sec(all.endError)) off on average.")
        lines.append("")
        lines.append("Note: rallies you didn't touch count as real, so this is generous to Find Rallies on matches you only skimmed.")
        lines.append("")
        lines.append("| Match | F1 | Found | Real | Matched | Short found | Start / end off | Missed (first 5) | Not real (first 5) |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for r in results {
            lines.append("| \(r.name) | \(pct(r.f1)) | \(r.found) | \(r.real) | \(r.matched) | \(r.shortMatched)/\(r.short) | "
                         + "\(sec(r.startError)) / \(sec(r.endError)) | \(r.missed.prefix(5).map(clock).joined(separator: ", ")) | "
                         + "\(r.extra.prefix(5).map(clock).joined(separator: ", ")) |")
        }
        if !skipped.isEmpty {
            lines.append("")
            lines.append("Not scored: " + skipped.joined(separator: "; "))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

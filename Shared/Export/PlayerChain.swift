import Foundation

/// Follows one player through a whole clip at once, rather than frame by frame. First the people
/// found in each frame are joined into short pieces ("tracklets") wherever it's clear who's who:
/// the same size, barely moved, nobody else close. Pieces end where it isn't clear (two players
/// crossing, someone hidden). Then the player's path is the chain of pieces from where they were
/// pointed out that fits one person best: each piece starting about where and how big the last
/// ended (allowing for how they were moving), looking like them, and wearing their number when it
/// could be read. Because it sees the whole clip, a number read later settles who was who at a
/// crossing earlier, which following frame by frame can't do. Plain logic, tested on detections
/// from real clips; `PlayerTracker` feeds it Vision's.
enum PlayerChain {
    /// Receives a description of the pieces and the chain chosen, when set (for tuning).
    nonisolated(unsafe) static var debug: ((String) -> Void)?

    /// How the chain weighs things, tuned on real clips (see scripts/test-player-chain.sh).
    struct Settings {
        /// Worth of each frame a piece covers (before looks, size and numbers).
        var perFrame = 0.3
        /// Cost of a link's distance (as a share of how far they could have got), its change in
        /// size, and each second of gap.
        var distanceCost = 6.0
        var sizeCost = 8.0
        var gapCost = 4.0
        /// How far a player can get: this many of their heights, plus this many per second.
        var reach = 0.4
        var reachPerSecond = 1.5
        /// Weight of looking like them (see `likenesses`): the share a piece's worth rises per
        /// spread above the typical piece.
        var lookWeight = 0.3
    }
    nonisolated(unsafe) static var settings = Settings()
    /// A person found in a frame, in Vision's normalized picture coordinates (origin bottom-left).
    struct Person {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// Appearance fingerprint (unit length), if one was taken.
        var look: [Float]?
        /// Jersey number read on them in this frame, if any.
        var number: Int?

        var head: (x: Double, y: Double) { (x + width / 2, y + height) }
        var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
    }

    struct Frame {
        var time: Double
        var people: [Person]
    }

    /// Where the user pointed the player out: a spotlight ring (around their body) or a click
    /// (on their head), in Vision coordinates.
    struct Anchor {
        enum Kind { case body, head }
        var time: Double
        var x: Double
        var y: Double
        var kind: Kind
    }

    /// One person followed through consecutive frames: (frame index, person index) pairs.
    struct Tracklet {
        var members: [(frame: Int, person: Int)] = []
    }

    /// Where the player is in each frame (nil where the chain has a gap).
    static func follow(_ frames: [Frame], anchors: [Anchor], number: Int?, aspect: Double) -> [Person?] {
        guard !frames.isEmpty, !anchors.isEmpty else { return Array(repeating: nil, count: frames.count) }
        let pieces = tracklets(frames, aspect: aspect)
        var pieceOf: [[Int]] = frames.map { Array(repeating: -1, count: $0.people.count) }
        for (k, piece) in pieces.enumerated() {
            for m in piece.members { pieceOf[m.frame][m.person] = k }
        }
        // The pieces the user pointed at.
        var required: [(piece: Int, frame: Int)] = []
        for anchor in anchors.sorted(by: { $0.time < $1.time }) {
            guard let f = frames.indices.min(by: { abs(frames[$0].time - anchor.time) < abs(frames[$1].time - anchor.time) }),
                  let p = pointedAt(frames[f].people, anchor: anchor, aspect: aspect) else { continue }
            let k = pieceOf[f][p]
            if !required.contains(where: { $0.piece == k }) { required.append((k, f)) }
        }
        guard !required.isEmpty else { return Array(repeating: nil, count: frames.count) }

        let summaries = pieces.map { summarize($0, frames) }
        let seedLook = averageLook(required.compactMap { summaries[$0.piece].look })
        // The number seen on the player pointed out wins over the expected one (the reel may be
        // about someone else, or the player card out of date).
        let target = requiredNumber(required.map { summaries[$0.piece] }) ?? number
        let seedHeight = required.map { summaries[$0.piece].first.height }.reduce(0, +) / Double(required.count)
        let likeness = likenesses(summaries, seedLook: seedLook)
        let values = summaries.indices.map { value(summaries[$0], likeness: likeness[$0], seedHeight: seedHeight, number: target) }

        // Pieces that can't be them: at the same time as a piece they were pointed out in.
        var excluded = Set<Int>()
        for (k, s) in summaries.enumerated() where !required.contains(where: { $0.piece == k }) {
            for r in required where summaries[r.piece].overlaps(s) { excluded.insert(k) }
        }

        // Forward from the first piece pointed out, and backward from it to the start.
        let first = required[0].piece
        let mustVisit = Set(required.map(\.piece))
        let forward = bestChain(from: first, pieces: summaries, values: values, excluded: excluded,
                                mustVisit: mustVisit, aspect: aspect, backward: false)
        let backward = bestChain(from: first, pieces: summaries, values: values, excluded: excluded,
                                 mustVisit: mustVisit, aspect: aspect, backward: true)
        if let debug {
            for k in (backward.reversed() + forward.dropFirst()) {
                let s = summaries[k]
                debug(String(format: "piece %d  %.2f-%.2fs  head %.3f,%.3f → %.3f,%.3f  h %.3f  value %.1f  numbers %@",
                             k, s.startTime, s.endTime, s.first.head.x, s.first.head.y, s.last.head.x, s.last.head.y,
                             s.first.height, values[k] ?? -1, "\(s.numbers)"))
            }
        }
        var out: [Person?] = Array(repeating: nil, count: frames.count)
        for k in Set(forward + backward) {
            for m in pieces[k].members { out[m.frame] = frames[m.frame].people[m.person] }
        }
        return out
    }

    // MARK: Pieces

    /// Joins people frame to frame where it's clear: each piece is matched with the person
    /// nearest where it was heading, about the same size, with nobody else nearly as close. A
    /// piece waits up to `bridge` frames for someone who went missing (the detector skips people
    /// now and then, especially when they overlap).
    static func tracklets(_ frames: [Frame], aspect: Double, bridge: Int = 6) -> [Tracklet] {
        var pieces: [Tracklet] = []
        /// `height` is their full height, kept while they're partly hidden (box much shorter).
        struct Open { var piece: Int; var frame: Int; var person: Person; var velocity: (x: Double, y: Double); var height: Double }
        var open: [Open] = []
        for (f, frame) in frames.enumerated() {
            open.removeAll { f - $0.frame > bridge + 1 }
            // Costs of every open piece against every person here, in the piece's heights
            // per frame (so a piece that waited a frame may have moved twice as far).
            var pairs: [(o: Int, p: Int, cost: Double)] = []
            for (o, piece) in open.enumerated() {
                let a = piece.person
                let dt = max(0.001, frame.time - frames[piece.frame].time)
                let steps = Double(f - piece.frame)
                let carry = min(dt, 0.2)
                let px = a.head.x + piece.velocity.x * carry, py = a.head.y + piece.velocity.y * carry
                for (j, b) in frame.people.enumerated() {
                    let dx = (b.head.x - px) * aspect / piece.height, dy = (b.head.y - py) / piece.height
                    let distance = (dx * dx + dy * dy).squareRoot() / steps
                    // Growing is someone else (nearer the camera); shrinking with the head in
                    // place is them half hidden.
                    var size = log(b.height / piece.height)
                    if size < 0, distance < 0.15 { size = max(size, -0.3) * 0.3 }
                    guard abs(size) < 0.35 else { continue }
                    let cost = distance + abs(size)
                    if cost < 0.45 { pairs.append((o, j, cost)) }
                }
            }
            pairs.sort { $0.cost < $1.cost }
            var takenOpen = Set<Int>(), takenPeople = Set<Int>(), joined: [Int: Int] = [:]
            for pair in pairs where !takenOpen.contains(pair.o) && !takenPeople.contains(pair.p) {
                // Clear only if nobody else is nearly as good a match, either way.
                let margin = max(0.08, pair.cost * 0.6)
                let rival = pairs.contains { other in
                    (other.o == pair.o) != (other.p == pair.p) && other.cost < pair.cost + margin
                        && !takenOpen.contains(other.o) && !takenPeople.contains(other.p)
                }
                takenOpen.insert(pair.o)
                takenPeople.insert(pair.p)
                guard !rival else { continue }
                joined[pair.p] = pair.o
            }
            var next: [Open] = open.enumerated().filter { !takenOpen.contains($0.offset) }.map(\.element)
            for (j, person) in frame.people.enumerated() {
                if let o = joined[j] {
                    let was = open[o]
                    let dt = max(0.001, frame.time - frames[was.frame].time)
                    let v = ((person.head.x - was.person.head.x) / dt, (person.head.y - was.person.head.y) / dt)
                    pieces[was.piece].members.append((f, j))
                    let height = person.height < was.height * 0.8 ? was.height : was.height * 0.7 + person.height * 0.3
                    next.append(Open(piece: was.piece, frame: f, person: person,
                                     velocity: (was.velocity.x * 0.5 + v.0 * 0.5, was.velocity.y * 0.5 + v.1 * 0.5),
                                     height: height))
                } else {
                    pieces.append(Tracklet(members: [(f, j)]))
                    next.append(Open(piece: pieces.count - 1, frame: f, person: person, velocity: (0, 0), height: person.height))
                }
            }
            open = next
        }
        return pieces
    }

    /// What the chain needs to know about a piece.
    struct Summary {
        var startTime: Double
        var endTime: Double
        var first: Person
        var last: Person
        /// Head speed at the end and start (picture fractions per second), for predicting where
        /// the next piece begins.
        var endVelocity: (x: Double, y: Double)
        var startVelocity: (x: Double, y: Double)
        var frames: Int
        var look: [Float]?
        var numbers: [Int: Int]

        func overlaps(_ other: Summary) -> Bool {
            startTime < other.endTime - 0.01 && other.startTime < endTime - 0.01
        }
    }

    static func summarize(_ piece: Tracklet, _ frames: [Frame]) -> Summary {
        let people = piece.members.map { frames[$0.frame].people[$0.person] }
        let times = piece.members.map { frames[$0.frame].time }
        func velocity(_ a: Int, _ b: Int) -> (x: Double, y: Double) {
            let dt = times[b] - times[a]
            guard dt > 0.01 else { return (0, 0) }
            return ((people[b].head.x - people[a].head.x) / dt, (people[b].head.y - people[a].head.y) / dt)
        }
        let n = people.count
        var numbers: [Int: Int] = [:]
        for p in people { if let number = p.number { numbers[number, default: 0] += 1 } }
        return Summary(startTime: times[0], endTime: times[n - 1], first: people[0], last: people[n - 1],
                       endVelocity: velocity(max(0, n - 5), n - 1), startVelocity: velocity(0, min(n - 1, 4)),
                       frames: n, look: averageLook(people.compactMap(\.look)), numbers: numbers)
    }

    static func averageLook(_ looks: [[Float]]) -> [Float]? {
        guard let first = looks.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for look in looks where look.count == sum.count { for i in sum.indices { sum[i] += look[i] } }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? sum.map { $0 / norm } : nil
    }

    static func similarity(_ a: [Float]?, _ b: [Float]?) -> Double? {
        guard let a, let b, a.count == b.count else { return nil }
        return Double(zip(a, b).reduce(0) { $0 + $1.0 * $1.1 })
    }

    /// How much each piece looks like them compared with the other pieces in the clip: how many
    /// spreads above (positive) or below the typical piece, capped at ±2. Relative, so it means
    /// the same whatever appearance model made the looks.
    static func likenesses(_ pieces: [Summary], seedLook: [Float]?) -> [Double] {
        let sims = pieces.map { similarity($0.look, seedLook) }
        let known = sims.compactMap { $0 }.sorted()
        guard known.count >= 5 else { return Array(repeating: 0, count: pieces.count) }
        let median = known[known.count / 2]
        let spread = max(0.01, known[known.count * 3 / 4] - known[known.count / 4])
        return sims.map { $0.map { min(2, max(-2, ($0 - median) / spread)) } ?? 0 }
    }

    /// The number clearly read on the pieces pointed out: at least three times, and most of
    /// what was read there (a box sometimes takes in a teammate's number too).
    static func requiredNumber(_ pieces: [Summary]) -> Int? {
        var counts: [Int: Int] = [:]
        for p in pieces { for (n, c) in p.numbers { counts[n, default: 0] += c } }
        let total = counts.values.reduce(0, +)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 3,
              Double(top.value) >= Double(total) * 0.7 else { return nil }
        return top.key
    }

    /// How much a piece adds to a chain: its length, more when it looks like them or shows their
    /// number, nothing (excluded) when it plainly shows another number. Pieces far bigger or
    /// smaller than when they were pointed out count for little.
    static func value(_ s: Summary, likeness: Double, seedHeight: Double, number: Int?) -> Double? {
        var perFrame = settings.perFrame * (1 + likeness * settings.lookWeight)
        // Players run from the sideline to the net, so allow a lot (half to twice the size);
        // beyond that it's someone right by the camera, or a spectator far behind the court.
        let height = max(s.first.height, s.last.height)
        let scale = abs(log(height / max(seedHeight, 0.001)))
        perFrame *= max(0.05, 1 - max(0, scale - 0.75) * 2.5)
        var bonus = 0.0
        if let number {
            let mine = s.numbers[number] ?? 0
            let others = s.numbers.filter { $0.key != number }.values.reduce(0, +)
            if others >= 2, others > mine * 2 { return nil }
            bonus += Double(mine) * 20 - Double(others) * 6
        }
        return max(0.2 * settings.perFrame, perFrame) * Double(s.frames) + bonus
    }

    /// Who the user pointed at: for a spotlight, the person whose body the ring is on; for a
    /// click, the person whose head is nearest it (only people whose top part it's in, so a big
    /// player in front doesn't win just because the click is inside their box).
    static func pointedAt(_ people: [Person], anchor: Anchor, aspect: Double) -> Int? {
        switch anchor.kind {
        case .body:
            let inside = people.indices.filter {
                let p = people[$0]
                return anchor.x >= p.x && anchor.x <= p.x + p.width && anchor.y >= p.y && anchor.y <= p.y + p.height
            }
            func d(_ i: Int) -> Double { hypot((people[i].center.x - anchor.x) * aspect, people[i].center.y - anchor.y) }
            return (inside.isEmpty ? Array(people.indices) : inside).min { d($0) < d($1) }
        case .head:
            func d(_ i: Int) -> Double {
                hypot((people[i].head.x - anchor.x) * aspect, people[i].head.y - anchor.y) / people[i].height
            }
            return people.indices.filter { d($0) < 0.35 }.min { d($0) < d($1) }
                ?? people.indices.min { d($0) < d($1) }
        }
    }

    // MARK: The chain

    /// Cost of going from piece `a` to piece `b` (forward in time), or nil if one person couldn't
    /// do that: too far for the time between, or suddenly much bigger.
    static func link(_ a: Summary, _ b: Summary, aspect: Double) -> Double? {
        let gap = b.startTime - a.endTime
        guard gap > -0.08, gap < 2.5 else { return nil }
        let g = max(0, gap)
        let carry = min(g, 0.5)
        let px = a.last.head.x + a.endVelocity.x * carry, py = a.last.head.y + a.endVelocity.y * carry
        let h = a.last.height
        let dx = (b.first.head.x - px) * aspect / h, dy = (b.first.head.y - py) / h
        let distance = (dx * dx + dy * dy).squareRoot()
        let reach = settings.reach + settings.reachPerSecond * g
        guard distance <= reach else { return nil }
        let size = log(b.first.height / h)
        // Bigger means someone nearer the camera; smaller is often them half hidden.
        guard size <= 0.3 + 0.3 * g, size >= -(0.7 + 0.3 * g) else { return nil }
        return settings.distanceCost * distance / reach + settings.sizeCost * (size > 0 ? size : -size * 0.5)
            + settings.gapCost * g
    }

    /// The best chain from `start` (forward to the end, or backward to the beginning): the most
    /// value for the least strain, passing through every piece in `mustVisit` on its side.
    static func bestChain(from start: Int, pieces: [Summary], values: [Double?], excluded: Set<Int>,
                          mustVisit: Set<Int>, aspect: Double, backward: Bool) -> [Int] {
        let s0 = pieces[start]
        // Pieces on this side of the start, in the order the chain meets them.
        let side = pieces.indices.filter { k in
            k != start && !excluded.contains(k) && values[k] != nil
                && (backward ? pieces[k].endTime <= s0.startTime + 0.08 : pieces[k].startTime >= s0.endTime - 0.08)
        }.sorted { backward ? pieces[$0].endTime > pieces[$1].endTime : pieces[$0].startTime < pieces[$1].startTime }
        let order = [start] + side
        var best = [Double](repeating: -.infinity, count: order.count)
        var from = [Int](repeating: -1, count: order.count)
        best[0] = 0
        for i in 1..<order.count {
            let b = pieces[order[i]]
            let worth = (values[order[i]] ?? 0) + (mustVisit.contains(order[i]) ? 10_000 : 0)
            for j in 0..<i where best[j] > -.infinity {
                let a = pieces[order[j]]
                guard let cost = backward ? link(b, a, aspect: aspect) : link(a, b, aspect: aspect) else { continue }
                let total = best[j] + worth - cost
                if total > best[i] { best[i] = total; from[i] = j }
            }
        }
        guard var i = best.indices.max(by: { best[$0] < best[$1] }) else { return [start] }
        var chain: [Int] = []
        while i >= 0 { chain.append(order[i]); i = from[i] }
        return chain
    }
}

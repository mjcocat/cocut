import Accelerate
import CoreGraphics
import Foundation

/// Groups the followed stretches of players (tracks) into people, so Cocut asks "who's this?"
/// once per person instead of once per stretch.
///
/// - Players Cocut is sure of come first: stretches you identified, and stretches whose number was
///   read clearly. Each number's stretches make one known player. A few reads spread over a group
///   of look-alikes only make a guess, not a decision.
/// - The other stretches are joined into people only when they look like *most* of each other,
///   not just like one of them. So a chain of look-alikes (A like B, B like C) never makes A and C
///   the same person, which is what used to merge different teammates.
/// - A person nobody vouches for is then matched to a known player only when they look clearly
///   more like that player than like any other. Matched people stay separate, so they never pull
///   further people in.
/// - Two stretches seen in the same moment are never the same person, and stretches you said
///   aren't someone (unticked in Who's This?) are never joined to them.
/// - How alike counts as "the same person" is learned from the film itself: the two halves of one
///   stretch are the same person; two players on screen together are not.
enum PlayerGrouping {
    struct Person: Identifiable, Sendable, Hashable {
        var id: Int
        var tracks: [Int]
        /// Frames per stretch.
        var trackFrames: [Int: Int]
        /// Frames over all its stretches.
        var frames: Int
        /// Their tallest box (share of the picture height): small means hard to recognize.
        var maxHeight: Double
        /// Who it is, when decided (a jersey number, or `RallyDetector.otherTeam`).
        var number: Int?
        var source: RallyDetector.TrackDecision.Source
        /// Who it most looks like, when undecided.
        var guess: Int?
        /// Numbers read on this person, with counts.
        var reads: [Int: Int]
    }

    struct Result: Sendable {
        var people: [Person]
        /// Track → decision, for listing players on rallies.
        var decisions: [Int: RallyDetector.TrackDecision]
        /// Tracks that are boxes around several people.
        var groupTracks: Set<Int>
        /// The learned "same person" similarity.
        var threshold: Float
        /// Frames of single players in all.
        var totalFrames: Int
        /// Players known from an answer or a clear read, which the rest are matched to.
        var anchors: Int = 0
        /// People matched to a known player by how they look.
        var matched: Int = 0
    }

    // Tuning, in one place so each change can be scored with Check Accuracy.
    /// Share of stretch pairs between two people that must look alike to join them.
    static let linkShare: Float = 0.6
    /// How far under the threshold the two people's average likeness may be.
    static let linkSlack: Float = 0.03
    /// Stretches compared per person (their longest), to keep joining quick.
    static let sampleSize = 12
    /// The most stretches a person nobody vouches for can grow to.
    static let maxUnvouched = 40
    /// How much more a person must look like one known player than the next to be matched.
    static let matchMargin: Float = 0.04
    /// A known player's closest stretches that count when matching someone to them.
    static let matchTop = 3
    /// A known player's stretches compared when matching (their longest).
    static let referenceSize = 60

    /// - Parameters:
    ///   - taughtTracks: stretches the user identified.
    ///   - notTracks: stretches the user said aren't a player (track → numbers it isn't).
    ///   - remembered: appearance prints (without jersey color) of players known from earlier
    ///     matches or clicked on a frame, by number.
    ///   - strictness: added to the learned threshold when matching undecided people to known
    ///     players (negative is looser).
    static func group(sightings: [RallyDetector.PersonSighting], taughtTracks: [Int: Int],
                      notTracks: [Int: Set<Int>] = [:],
                      remembered: [Int: [[Float]]], strictness: Float = 0) -> Result {
        guard let printDims = sightings.first?.print.count, printDims > 0 else {
            return Result(people: [], decisions: [:], groupTracks: [], threshold: 0, totalFrames: 0)
        }
        let dims = printDims + 3

        // 1. Boxes around several people: they contain another player's center, or are wider than
        //    one standing or crouching player (on a 16:9 picture).
        var isGroupSighting = [Bool](repeating: false, count: sightings.count)
        let byTime = Dictionary(grouping: sightings.indices, by: { sightings[$0].time })
        for (_, members) in byTime {
            for i in members {
                let box = sightings[i].box
                var inside = 0
                for j in members where j != i {
                    let other = sightings[j].box
                    if box.contains(CGPoint(x: other.midX, y: other.midY)) { inside += 1 }
                }
                if inside >= 1 || box.width * 16 / 9 / max(box.height, 0.001) > 0.9 { isGroupSighting[i] = true }
            }
        }

        // 2. One description per stretch: its average look (with jersey color), when it was on screen,
        //    and the numbers read on it.
        struct Stretch {
            var track: Int
            var members: [Int]
            var vector: [Float]
            var printOnly: [Float]
            var start: Double
            var end: Double
            var reads: [Int: Int]
        }
        var groupTracks: Set<Int> = []
        var stretches: [Stretch] = []
        for (track, members) in Dictionary(grouping: sightings.indices, by: { sightings[$0].track }) {
            let single = members.filter { !isGroupSighting[$0] }
            if single.count * 2 < members.count { groupTracks.insert(track); continue }
            guard !single.isEmpty else { continue }
            var sum = [Float](repeating: 0, count: dims)
            var printSum = [Float](repeating: 0, count: printDims)
            var reads: [Int: Int] = [:]
            for m in single {
                sum = vDSP.add(sum, RallyDetector.features(sightings[m].print, color: sightings[m].color))
                if sightings[m].print.count == printDims { printSum = vDSP.add(printSum, sightings[m].print) }
                if let n = sightings[m].number { reads[n, default: 0] += 1 }
            }
            let times = single.map { sightings[$0].time }
            stretches.append(Stretch(track: track, members: single, vector: unit(sum), printOnly: unit(printSum),
                                     start: times.min()!, end: times.max()!, reads: reads))
        }
        stretches.sort { $0.track < $1.track }
        let n = stretches.count
        guard n > 0 else {
            return Result(people: [], decisions: [:], groupTracks: groupTracks, threshold: 0, totalFrames: 0)
        }
        func overlaps(_ a: Stretch, _ b: Stretch) -> Bool { a.start <= b.end + 0.25 && b.start <= a.end + 0.25 }

        // 3. Similarities, a block of rows at a time (a full n×n table is too big on a long film):
        //    each stretch's closest look-alikes, and players on screen together.
        var filling = [Float](repeating: 0, count: n * dims)
        for (i, s) in stretches.enumerated() { filling.replaceSubrange(i * dims..<(i + 1) * dims, with: s.vector) }
        let matrix = filling
        var transposed = [Float](repeating: 0, count: n * dims)
        vDSP_mtrans(matrix, 1, &transposed, 1, vDSP_Length(dims), vDSP_Length(n))
        var neighbors: [[(Float, Int)]] = Array(repeating: [], count: n)
        var different: [Float] = []
        let block = 256
        var rows = [Float](repeating: 0, count: block * n)
        for start in stride(from: 0, to: n, by: block) {
            let count = min(block, n - start)
            matrix.withUnsafeBufferPointer { m in
                vDSP_mmul(m.baseAddress! + start * dims, 1, transposed, 1, &rows, 1,
                          vDSP_Length(count), vDSP_Length(n), vDSP_Length(dims))
            }
            for r in 0..<count {
                let i = start + r
                var near: [(Float, Int)] = []
                for j in 0..<n where j != i {
                    let sim = rows[r * n + j]
                    if overlaps(stretches[i], stretches[j]) {
                        if j > i && different.count < 40_000 { different.append(sim) }
                    } else if sim >= 0.5 {
                        near.append((sim, j))
                    }
                }
                neighbors[i] = Array(near.sorted { $0.0 > $1.0 }.prefix(20))
            }
        }
        transposed = []
        rows = []
        /// How alike two stretches look.
        func sim(_ i: Int, _ j: Int) -> Float {
            var r: Float = 0
            matrix.withUnsafeBufferPointer { m in
                vDSP_dotpr(m.baseAddress! + i * dims, 1, m.baseAddress! + j * dims, 1, &r, vDSP_Length(dims))
            }
            return r
        }

        // 4. Learn "same person" from the film: halves of long stretches vs. players on screen together.
        var same: [Float] = []
        for s in stretches where s.members.count >= 8 {
            let sorted = s.members.sorted { sightings[$0].time < sightings[$1].time }
            let half = sorted.count / 2
            func mean(_ idx: ArraySlice<Int>) -> [Float] {
                var v = [Float](repeating: 0, count: dims)
                for m in idx { v = vDSP.add(v, RallyDetector.features(sightings[m].print, color: sightings[m].color)) }
                return unit(v)
            }
            same.append(RallyDetector.dot(mean(sorted[..<half]), mean(sorted[half...])))
        }
        let threshold = bestSplit(same: same, different: different)

        // 5. People. Each starts as one stretch; `root` is the stretch that stands for the person.
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var members: [[Int]] = (0..<n).map { [$0] }
        var spans: [[(Double, Double)]] = stretches.map { [($0.start, $0.end)] }
        /// What you said they are.
        var label: [Int?] = stretches.map { taughtTracks[$0.track] }
        /// Numbers you said they aren't.
        var nots: [Set<Int>] = stretches.map { notTracks[$0.track] ?? [] }
        var readVotes: [[Int: Int]] = stretches.map(\.reads)
        /// Who they're vouched to be: your answer, else a clear read (unless you said they aren't).
        var vouched: [Int?] = (0..<n).map { i in
            if let l = label[i] { return l == RallyDetector.otherTeam ? nil : l }
            guard let read = strongRead(stretches[i].reads), !nots[i].contains(read) else { return nil }
            return read
        }
        /// Answered (including "not our team") or vouched for: never joined by look alone.
        func known(_ r: Int) -> Bool { label[r] != nil || vouched[r] != nil }
        func identity(_ r: Int) -> Int? { label[r] ?? vouched[r] ?? strongRead(readVotes[r]) }

        func compatible(_ a: Int, _ b: Int) -> Bool {
            // Not on screen at the same time.
            for x in spans[a] { for y in spans[b] where x.0 <= y.1 + 0.25 && y.0 <= x.1 + 0.25 { return false } }
            // Not identified as different people.
            if let la = label[a], let lb = label[b], la != lb { return false }
            if let va = vouched[a], let vb = vouched[b], va != vb { return false }
            // Not said to be someone the other isn't.
            if let ia = identity(a), nots[b].contains(ia) { return false }
            if let ib = identity(b), nots[a].contains(ib) { return false }
            // Not clearly read as different numbers.
            if let ra = strongRead(readVotes[a]), let rb = strongRead(readVotes[b]), ra != rb { return false }
            return true
        }
        func join(_ a: Int, _ b: Int) {
            parent[b] = a
            members[a].append(contentsOf: members[b])
            members[b] = []
            spans[a].append(contentsOf: spans[b])
            if label[a] == nil { label[a] = label[b] }
            if vouched[a] == nil { vouched[a] = vouched[b] }
            nots[a].formUnion(nots[b])
            for (k, v) in readVotes[b] { readVotes[a][k, default: 0] += v }
        }

        // 5a. Known players: each number's answered stretches, then its clearly read ones (longest
        //     first), make one person. A stretch that clashes (on screen at the same moment, so a
        //     misread) stays on its own.
        let byNumber = Dictionary(grouping: (0..<n).filter { vouched[$0] != nil }, by: { vouched[$0]! })
        for (_, list) in byNumber {
            let ordered = list.sorted { a, b in
                let ta = label[a] != nil, tb = label[b] != nil
                if ta != tb { return ta }
                return stretches[a].members.count > stretches[b].members.count
            }
            for m in ordered.dropFirst() {
                let a = find(ordered[0]), b = find(m)
                if a != b, compatible(a, b) { join(a, b) }
            }
        }

        // 5b. Everyone else: join look-alikes, most alike first, only when the two people look like
        //     most of each other's stretches (compared on their longest ones).
        func representatives(_ list: [Int], _ limit: Int) -> [Int] {
            guard list.count > limit else { return list }
            return Array(list.sorted { stretches[$0].members.count > stretches[$1].members.count }.prefix(limit))
        }
        func linked(_ a: [Int], _ b: [Int]) -> Bool {
            let ra = representatives(a, sampleSize), rb = representatives(b, sampleSize)
            var close = 0
            var total: Float = 0
            for x in ra {
                for y in rb {
                    let s = sim(x, y)
                    total += s
                    if s >= threshold { close += 1 }
                }
            }
            let pairs = Float(ra.count * rb.count)
            return Float(close) >= (linkShare * pairs).rounded(.up) && total / pairs >= threshold - linkSlack
        }
        var pairs: [(Float, Int, Int)] = []
        for i in 0..<n {
            for (s, j) in neighbors[i] where s >= threshold && i < j { pairs.append((s, i, j)) }
            for (s, j) in neighbors[i] where s >= threshold && j < i
                && !neighbors[j].contains(where: { $0.1 == i }) { pairs.append((s, j, i)) }
        }
        pairs.sort { $0.0 > $1.0 }
        for (_, i, j) in pairs {
            let a = find(i), b = find(j)
            guard a != b, !known(a), !known(b), members[a].count + members[b].count <= maxUnvouched,
                  compatible(a, b), linked(members[a], members[b]) else { continue }
            join(a, b)
        }

        // 6. Who each person is.
        var people: [Person] = []
        var rootOf: [Int: Int] = [:] // person id → root stretch index
        for root in 0..<n where parent[root] == root {
            let list = members[root]
            let frames = list.reduce(0) { $0 + stretches[$1].members.count }
            var trackFrames: [Int: Int] = [:]
            for idx in list { trackFrames[stretches[idx].track] = stretches[idx].members.count }
            let tallest = list.flatMap { stretches[$0].members }.map { Double(sightings[$0].box.height) }.max() ?? 0
            var person = Person(id: stretches[root].track, tracks: list.map { stretches[$0].track },
                                trackFrames: trackFrames, frames: frames, maxHeight: tallest,
                                number: nil, source: .uncertain, guess: nil, reads: readVotes[root])
            if let taught = label[root] {
                person.number = taught
                person.source = .taught
            } else if let read = vouched[root] {
                // Only a clear read on one of their stretches names them. A few reads spread over
                // a group joined by look don't: in one match a 35-stretch group with #11 read
                // twice was named #11, and a third of its frames were other players.
                person.number = read
                person.source = .read
            }
            rootOf[person.id] = root
            people.append(person)
        }

        // 7. Undecided people: the known player they look clearly most like (or a player remembered
        //    from earlier matches). Compared stretch by stretch with the known player's closest
        //    stretches, so a player seen a lot doesn't blur into an average.
        struct Reference {
            var number: Int
            var root: Int
            /// The reference's stretches, transposed (dims × count) for one multiply.
            var transposed: [Float]
            var count: Int
        }
        var references: [Reference] = []
        for p in people where p.source == .taught || p.source == .read {
            guard let number = p.number, let root = rootOf[p.id] else { continue }
            let list = representatives(members[root], referenceSize)
            var block = [Float](repeating: 0, count: list.count * dims)
            for (k, idx) in list.enumerated() {
                block.replaceSubrange(k * dims..<(k + 1) * dims, with: matrix[idx * dims..<(idx + 1) * dims])
            }
            var t = [Float](repeating: 0, count: list.count * dims)
            vDSP_mtrans(block, 1, &t, 1, vDSP_Length(dims), vDSP_Length(list.count))
            references.append(Reference(number: number, root: root, transposed: t, count: list.count))
        }
        var rememberedVectors: [(Int, [Float])] = []
        for (number, prints) in remembered { for p in prints where p.count == printDims { rememberedVectors.append((number, unit(p))) } }

        var matched = 0
        for i in people.indices where people[i].number == nil {
            guard let root = rootOf[people[i].id] else { continue }
            let reps = representatives(members[root], sampleSize)
            var mine = [Float](repeating: 0, count: reps.count * dims)
            for (k, idx) in reps.enumerated() {
                mine.replaceSubrange(k * dims..<(k + 1) * dims, with: matrix[idx * dims..<(idx + 1) * dims])
            }
            var bestByNumber: [Int: Float] = [:]
            for ref in references {
                // Not someone on screen at the same moment, or someone you said they aren't. "Not
                // our team" is many people, so being on screen with some of them rules nothing out.
                guard !nots[root].contains(ref.number),
                      compatible(root, ref.root) || label[ref.root] == RallyDetector.otherTeam else { continue }
                var sims = [Float](repeating: 0, count: reps.count * ref.count)
                vDSP_mmul(mine, 1, ref.transposed, 1, &sims, 1,
                          vDSP_Length(reps.count), vDSP_Length(ref.count), vDSP_Length(dims))
                var score: Float = 0
                let k = min(matchTop, ref.count)
                for r in 0..<reps.count {
                    let top = sims[(r * ref.count)..<((r + 1) * ref.count)].sorted(by: >).prefix(k)
                    score += top.reduce(0, +) / Float(k)
                }
                score /= Float(reps.count)
                if score > (bestByNumber[ref.number] ?? -1) { bestByNumber[ref.number] = score }
            }
            // Remembered players are compared by look alone (their uniform may have changed).
            var look = [Float](repeating: 0, count: printDims)
            for idx in members[root] { look = vDSP.add(look, stretches[idx].printOnly) }
            look = unit(look)
            for (num, p) in rememberedVectors where !nots[root].contains(num) {
                let s = RallyDetector.dot(look, p) - 0.03
                if s > (bestByNumber[num] ?? -1) { bestByNumber[num] = s }
            }
            // A number read a few times on them is the first guess to offer in Who's This?.
            let readGuess = strongRead(readVotes[root])
            let ranked = bestByNumber.sorted { $0.value > $1.value }
            guard let top = ranked.first else {
                people[i].guess = readGuess
                continue
            }
            people[i].guess = readGuess ?? top.key
            let second = ranked.count > 1 ? ranked[1].value : -1
            if top.value >= threshold + strictness && top.value - second >= matchMargin {
                people[i].number = top.key
                people[i].source = .matched
                matched += 1
            }
        }

        // 8. Per stretch, for the rally lists.
        var decisions: [Int: RallyDetector.TrackDecision] = [:]
        for p in people {
            for t in p.tracks {
                decisions[t] = RallyDetector.TrackDecision(track: t, number: p.number, source: p.source, guess: p.guess,
                                                           score: 0, margin: 0, count: p.frames)
            }
        }
        for t in groupTracks {
            decisions[t] = RallyDetector.TrackDecision(track: t, number: nil, source: .uncertain, guess: nil,
                                                       score: 0, margin: 0, count: 0, isGroup: true)
        }
        let total = people.reduce(0) { $0 + $1.frames }
        return Result(people: people.sorted { $0.frames > $1.frames }, decisions: decisions, groupTracks: groupTracks,
                      threshold: threshold, totalFrames: total,
                      anchors: references.filter { $0.number >= 0 }.count, matched: matched)
    }

    /// The number read on a stretch or person when it clearly wins: at least 3 reads and 60%.
    static func strongRead(_ votes: [Int: Int]) -> Int? {
        let total = votes.values.reduce(0, +)
        guard total >= 3, let top = votes.max(by: { $0.value < $1.value }), Double(top.value) >= 0.6 * Double(total) else { return nil }
        return top.key
    }

    /// The similarity that best separates "same person" from "different people" in this film.
    static func bestSplit(same: [Float], different: [Float]) -> Float {
        guard same.count >= 10, different.count >= 10 else { return 0.85 }
        let s = same.sorted(), d = different.sorted()
        var best: Float = 0.85, bestScore = -Double.infinity
        var t: Float = 0.5
        while t <= 0.99 {
            // Share of same-person pairs kept, minus share of different-people pairs wrongly joined.
            let keep = Double(s.count - lowerBound(s, t)) / Double(s.count)
            let wrong = Double(d.count - lowerBound(d, t)) / Double(d.count)
            let score = keep - 2 * wrong // joining two different people is worse than missing a join
            if score > bestScore { bestScore = score; best = t }
            t += 0.005
        }
        return best
    }

    private static func lowerBound(_ a: [Float], _ v: Float) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < v { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    static func unit(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}

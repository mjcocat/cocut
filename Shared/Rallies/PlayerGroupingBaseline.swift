import Accelerate
import CoreGraphics
import Foundation

/// The v0.21 grouping, frozen: stretches joined greedily, most alike first, checked only against
/// the joined person's average look. It chains different teammates into one "person", so it's no
/// longer used to decide anything. It's kept only so Check Accuracy can score the current
/// grouping against it on the same answers.
enum PlayerGroupingBaseline {
    /// - Parameters:
    ///   - taughtTracks: stretches the user identified.
    ///   - remembered: appearance prints (without jersey color) of players known from earlier
    ///     matches or clicked on a frame, by number.
    ///   - strictness: added to the learned threshold when matching undecided people to known
    ///     players (negative is looser).
    static func group(sightings: [RallyDetector.PersonSighting], taughtTracks: [Int: Int],
                      remembered: [Int: [[Float]]], strictness: Float = 0) -> PlayerGrouping.Result {
        guard let printDims = sightings.first?.print.count, printDims > 0 else {
            return PlayerGrouping.Result(people: [], decisions: [:], groupTracks: [], threshold: 0, totalFrames: 0)
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
            stretches.append(Stretch(track: track, members: single, vector: PlayerGrouping.unit(sum), printOnly: PlayerGrouping.unit(printSum),
                                     start: times.min()!, end: times.max()!, reads: reads))
        }
        stretches.sort { $0.track < $1.track }
        let n = stretches.count
        guard n > 0 else {
            return PlayerGrouping.Result(people: [], decisions: [:], groupTracks: groupTracks, threshold: 0, totalFrames: 0)
        }
        func overlaps(_ a: Stretch, _ b: Stretch) -> Bool { a.start <= b.end + 0.25 && b.start <= a.end + 0.25 }

        // 3. Similarities, a block of rows at a time (a full n×n table is too big on a long film):
        //    each stretch's closest look-alikes, and players on screen together.
        var matrix = [Float](repeating: 0, count: n * dims)
        for (i, s) in stretches.enumerated() { matrix.replaceSubrange(i * dims..<(i + 1) * dims, with: s.vector) }
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

        // 4. Learn "same person" from the film: halves of long stretches vs. players on screen together.
        var same: [Float] = []
        for s in stretches where s.members.count >= 8 {
            let sorted = s.members.sorted { sightings[$0].time < sightings[$1].time }
            let half = sorted.count / 2
            func mean(_ idx: ArraySlice<Int>) -> [Float] {
                var v = [Float](repeating: 0, count: dims)
                for m in idx { v = vDSP.add(v, RallyDetector.features(sightings[m].print, color: sightings[m].color)) }
                return PlayerGrouping.unit(v)
            }
            same.append(RallyDetector.dot(mean(sorted[..<half]), mean(sorted[half...])))
        }
        let threshold = PlayerGrouping.bestSplit(same: same, different: different)

        // 5. Join stretches into people, most alike first.
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var sums = stretches.map(\.vector)
        var spans: [[(Double, Double)]] = stretches.map { [($0.start, $0.end)] }
        var label: [Int?] = stretches.map { taughtTracks[$0.track] }
        var readVotes: [[Int: Int]] = stretches.map(\.reads)
        func compatible(_ a: Int, _ b: Int) -> Bool {
            // Not on screen at the same time.
            for x in spans[a] { for y in spans[b] where x.0 <= y.1 + 0.25 && y.0 <= x.1 + 0.25 { return false } }
            // Not identified as different people.
            if let la = label[a], let lb = label[b], la != lb { return false }
            // Not clearly read as different numbers.
            if let ra = PlayerGrouping.strongRead(readVotes[a]), let rb = PlayerGrouping.strongRead(readVotes[b]), ra != rb { return false }
            return true
        }
        func join(_ a: Int, _ b: Int) {
            parent[b] = a
            sums[a] = vDSP.add(sums[a], sums[b])
            spans[a].append(contentsOf: spans[b])
            if label[a] == nil { label[a] = label[b] }
            for (k, v) in readVotes[b] { readVotes[a][k, default: 0] += v }
        }
        // Stretches you identified as the same player belong together.
        // ("Not our team" covers many different people, so those aren't joined just for the label.)
        let taughtGroups = Dictionary(grouping: (0..<n).filter { label[$0] != nil && label[$0] != RallyDetector.otherTeam },
                                      by: { label[$0]! })
        for (_, same) in taughtGroups {
            for m in same.dropFirst() {
                let a = find(same[0]), b = find(m)
                if a != b, compatible(a, b) { join(a, b) }
            }
        }
        var pairs: [(Float, Int, Int)] = []
        for i in 0..<n {
            for (sim, j) in neighbors[i] where sim >= threshold && i < j { pairs.append((sim, i, j)) }
            for (sim, j) in neighbors[i] where sim >= threshold && j < i
                && !neighbors[j].contains(where: { $0.1 == i }) { pairs.append((sim, j, i)) }
        }
        pairs.sort { $0.0 > $1.0 }
        for (_, i, j) in pairs {
            let a = find(i), b = find(j)
            guard a != b, compatible(a, b) else { continue }
            // The joined person must still look like one person.
            if RallyDetector.dot(PlayerGrouping.unit(sums[a]), PlayerGrouping.unit(sums[b])) >= threshold { join(a, b) }
        }

        // 6. Who each person is.
        var personStretches: [Int: [Int]] = [:]
        for i in 0..<n { personStretches[find(i), default: []].append(i) }
        var people: [PlayerGrouping.Person] = []
        var rootOf: [Int: Int] = [:] // person id → root stretch index
        for (root, list) in personStretches {
            let frames = list.reduce(0) { $0 + stretches[$1].members.count }
            var trackFrames: [Int: Int] = [:]
            for idx in list { trackFrames[stretches[idx].track] = stretches[idx].members.count }
            let tallest = list.flatMap { stretches[$0].members }.map { Double(sightings[$0].box.height) }.max() ?? 0
            var person = PlayerGrouping.Person(id: stretches[root].track, tracks: list.map { stretches[$0].track },
                                trackFrames: trackFrames, frames: frames, maxHeight: tallest,
                                number: nil, source: .uncertain, guess: nil, reads: readVotes[root])
            if let taught = label[root] {
                person.number = taught
                person.source = .taught
            } else if let read = PlayerGrouping.strongRead(readVotes[root]) {
                person.number = read
                person.source = .read
            }
            rootOf[person.id] = root
            people.append(person)
        }

        // 7. Undecided people: whoever they look most like among decided people (and players
        //    remembered from earlier matches), when clearly so.
        var centroid: [Int: [Float]] = [:]
        var printCentroid: [Int: [Float]] = [:]
        for (root, list) in personStretches {
            centroid[root] = PlayerGrouping.unit(sums[root])
            var p = [Float](repeating: 0, count: printDims)
            for idx in list { p = vDSP.add(p, stretches[idx].printOnly) }
            printCentroid[root] = PlayerGrouping.unit(p)
        }
        let decided = people.filter { $0.number != nil }
        var rememberedVectors: [(Int, [Float])] = []
        for (number, prints) in remembered { for p in prints where p.count == printDims { rememberedVectors.append((number, PlayerGrouping.unit(p))) } }
        for i in people.indices where people[i].number == nil {
            guard let root = rootOf[people[i].id], let mine = centroid[root] else { continue }
            var bestByNumber: [Int: Float] = [:]
            for other in decided {
                guard let r = rootOf[other.id], let c = centroid[r], let num = other.number else { continue }
                let sim = RallyDetector.dot(mine, c)
                if sim > (bestByNumber[num] ?? -1) { bestByNumber[num] = sim }
            }
            // Remembered players are compared by look alone (their uniform may have changed).
            if let mineLook = printCentroid[root] {
                for (num, p) in rememberedVectors {
                    let sim = RallyDetector.dot(mineLook, p) - 0.03
                    if sim > (bestByNumber[num] ?? -1) { bestByNumber[num] = sim }
                }
            }
            let ranked = bestByNumber.sorted { $0.value > $1.value }
            guard let top = ranked.first else { continue }
            people[i].guess = top.key
            let second = ranked.count > 1 ? ranked[1].value : -1
            if top.value >= threshold + strictness && top.value - second >= 0.03 {
                people[i].number = top.key
                people[i].source = .matched
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
        return PlayerGrouping.Result(people: people.sorted { $0.frames > $1.frames }, decisions: decisions, groupTracks: groupTracks,
                      threshold: threshold, totalFrames: total)
    }
}

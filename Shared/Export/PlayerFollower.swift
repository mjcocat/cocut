import Foundation

/// Picks the spotlighted player out of each frame's detected people, the way you'd keep your eye
/// on someone in a crowd: where they were heading, how big they look, and, when it's close, the
/// number on their back and how they look. Size matters most in volleyball video: a teammate
/// walking between the camera and the net looks twice as big as the player at the net, so he's
/// never mistaken for them, however close he passes. Plain logic with no video, so it's tested on
/// its own; `PlayerTracker` feeds it Vision's detections.
struct PlayerFollower {
    /// A detected person, in Vision's normalized picture coordinates (origin bottom-left).
    struct Box: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        /// Where they stand (bottom middle), which moves more steadily than the middle of the box
        /// when they jump or reach.
        var foot: (x: Double, y: Double) { (x + width / 2, y) }
        var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
    }

    struct Settings {
        /// How much bigger or smaller (as a log ratio) someone may look from one moment to the
        /// next: ln(1.45). Grows while they're lost.
        var sizeTolerance = 0.37
        /// How far from where they were heading they may turn up, in their own heights.
        var reach = 0.9
        /// How much farther that gets per second they're lost.
        var lostReach = 1.6
        /// Candidates scoring this close to the best are worth a closer look (number, appearance).
        var ambiguity = 0.4
    }

    var settings = Settings()
    /// Picture width over height, so sideways and up-down distances compare fairly.
    let aspect: Double
    /// Their last box.
    private(set) var box: Box
    /// Their height, smoothed (detection boxes breathe as people bend and jump).
    private(set) var height: Double
    /// How their feet were moving, in picture fractions per second.
    private(set) var velocity: (x: Double, y: Double) = (0, 0)
    private(set) var lastSeen: Double
    /// Their jersey number: expected (from the player card) until read on them, then confirmed.
    private(set) var number: Int?
    private(set) var numberConfirmed = false
    /// The last moment their number was read on the box being followed.
    private(set) var lastConfirmed: Double?
    private var confirmedState: (box: Box, height: Double)?
    private var wrongReads = 0
    private var otherReads: [Int: Int] = [:]

    init(seed: Box, time: Double, aspect: Double, number: Int?) {
        box = seed
        height = seed.height
        lastSeen = time
        self.aspect = aspect
        self.number = number
    }

    /// Seconds since they were last picked out.
    func lostFor(at time: Double) -> Double { max(0, time - lastSeen) }

    /// Where their feet should be at `time`, carrying on as they were going (for a little while).
    func predicted(at time: Double) -> (x: Double, y: Double) {
        let dt = min(lostFor(at: time), 0.6)
        return (box.foot.x + velocity.x * dt, box.foot.y + velocity.y * dt)
    }

    /// The boxes that could be them at `time`, best first, each with a cost (lower is likelier).
    func gate(_ boxes: [Box], at time: Double) -> [(index: Int, cost: Double)] {
        let lost = max(0, lostFor(at: time) - 0.15)
        let sizeTolerance = min(0.9, settings.sizeTolerance + 0.3 * lost)
        let reach = settings.reach + settings.lostReach * lost
        let p = predicted(at: time)
        var out: [(index: Int, cost: Double)] = []
        for (i, b) in boxes.enumerated() where b.height > 0 {
            let size = log(b.height / height)
            guard abs(size) <= sizeTolerance else { continue }
            // In their own heights, so a step means the same near the camera and far from it.
            let dx = (b.foot.x - p.x) * aspect / height
            let dy = (b.foot.y - p.y) / height
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= reach else { continue }
            out.append((i, distance / max(reach, 0.001) + 1.5 * abs(size) / sizeTolerance))
        }
        return out.sorted { $0.cost < $1.cost }
    }

    /// Whether the best candidates are close enough that numbers and looks should decide.
    func isAmbiguous(_ gated: [(index: Int, cost: Double)]) -> Bool {
        gated.count >= 2 && gated[1].cost - gated[0].cost < settings.ambiguity
    }

    /// The candidate that's them, given numbers read on some of them and how much some look like
    /// them (-1...1), or nil if none is. Someone wearing another number is never them once their
    /// own number has been seen.
    func choose(_ gated: [(index: Int, cost: Double)], numbers: [Int: Int] = [:], looks: [Int: Float] = [:]) -> Int? {
        var best: (index: Int, cost: Double)?
        for g in gated {
            var cost = g.cost
            if let read = numbers[g.index], let number {
                if read == number {
                    cost -= 2
                } else if numberConfirmed {
                    continue
                } else {
                    cost += 0.8
                }
            }
            if let look = looks[g.index] { cost += Double(0.6 - look) * 1.5 }
            if cost < (best?.cost ?? .infinity) { best = (g.index, cost) }
        }
        return best?.index
    }

    /// They're in `b` at `time`.
    mutating func update(_ b: Box, at time: Double) {
        let dt = time - lastSeen
        if dt > 0.001 {
            let v = ((b.foot.x - box.foot.x) / dt, (b.foot.y - box.foot.y) / dt)
            // After a long gap the step is an average over it; trust it less.
            let weight = dt > 0.5 ? 0.25 : 0.5
            velocity = (velocity.x * (1 - weight) + v.0 * weight, velocity.y * (1 - weight) + v.1 * weight)
        }
        box = b
        height = height * 0.75 + b.height * 0.25
        lastSeen = time
    }

    /// A number read on the box being followed. Returns true when it shows the follower has
    /// slid onto someone else (their number was seen before, and now another, twice running).
    mutating func read(_ n: Int, at time: Double) -> Bool {
        if n == number {
            numberConfirmed = true
            lastConfirmed = time
            confirmedState = (box, height)
            wrongReads = 0
            return false
        }
        if !numberConfirmed {
            // The expected number hasn't shown up; if another keeps showing, it's theirs.
            otherReads[n, default: 0] += 1
            if otherReads[n, default: 0] >= 2 {
                number = n
                numberConfirmed = true
                lastConfirmed = time
                confirmedState = (box, height)
            }
            return false
        }
        wrongReads += 1
        return wrongReads >= 2
    }

    /// Following the wrong person since `lastConfirmed`: go back to how they were then, and look
    /// for them afresh.
    mutating func rewind() {
        if let confirmedState, let lastConfirmed {
            box = confirmedState.box
            height = confirmedState.height
            lastSeen = lastConfirmed
        }
        velocity = (0, 0)
        wrongReads = 0
    }
}

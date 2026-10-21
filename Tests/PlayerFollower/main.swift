import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok  \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}
typealias Box = PlayerFollower.Box
let aspect = 16.0 / 9.0
let fps = 15.0

/// A person in the synthetic clip: where their feet are and how tall they look at time t.
struct Person {
    var id: String
    var number: Int
    var foot: (Double) -> (x: Double, y: Double)
    var height: Double
    func box(at t: Double) -> Box {
        let f = foot(t)
        let w = height * 0.4 / aspect
        return Box(x: f.x - w / 2, y: f.y, width: w, height: height)
    }
}

/// Runs a follower over the clip. `visible` hides people (occlusion, missed detections);
/// `readable` says when a number can be read on someone. Returns who was followed each frame.
func run(_ people: [Person], seed: String, until end: Double, expected: Int?,
         visible: (Person, Double) -> Bool = { _, _ in true },
         readable: (Person, Double) -> Bool = { _, _ in false }) -> [String?] {
    let start = people.first { $0.id == seed }!
    var follower = PlayerFollower(seed: start.box(at: 0), time: 0, aspect: aspect, number: expected)
    var followed: [String?] = []
    var lastCheck = 0.0
    for frame in 1...Int(end * fps) {
        let t = Double(frame) / fps
        let shown = people.filter { visible($0, t) }
        let boxes = shown.map { $0.box(at: t) }
        let gated = follower.gate(boxes, at: t)
        var numbers: [Int: Int] = [:]
        if follower.isAmbiguous(gated) || follower.lostFor(at: t) > 0.3 {
            for g in gated.prefix(3) where readable(shown[g.index], t) { numbers[g.index] = shown[g.index].number }
        }
        if let i = follower.choose(gated, numbers: numbers) {
            follower.update(boxes[i], at: t)
            followed.append(shown[i].id)
            if t - lastCheck >= 0.5 {
                lastCheck = t
                if readable(shown[i], t), follower.read(shown[i].number, at: t) {
                    follower.rewind()
                    followed[followed.count - 1] = nil
                }
            }
        } else {
            followed.append(nil)
        }
    }
    return followed
}

print("A teammate walks between the camera and the net")
// #11 at the net (small, far), drifting right; #12 near the camera (twice the size) crosses in front.
let eleven = Person(id: "11", number: 11, foot: { t in (0.45 + 0.03 * t, 0.42) }, height: 0.24)
let twelve = Person(id: "12", number: 12, foot: { t in (0.15 + 0.25 * t, 0.06) }, height: 0.52)
let hidden: (Person, Double) -> Bool = { p, t in
    // #11 is hidden while #12 is in front of him.
    p.id != "11" || abs(twelve.foot(t).x - eleven.foot(t).x) > 0.07
}
let crossing = run([eleven, twelve], seed: "11", until: 4, expected: 11, visible: hidden)
check(!crossing.contains("12"), "never switches to the bigger player in front")
check(crossing.last == "11", "still on #11 after he passes")
check(crossing.contains(nil), "(he really was hidden for a moment)")

print("Two players the same size cross at the net")
let a = Person(id: "11", number: 11, foot: { t in (0.35 + 0.08 * t, 0.42) }, height: 0.24)
let b = Person(id: "30", number: 30, foot: { t in (0.6 - 0.08 * t, 0.43) }, height: 0.24)
let sameSize = run([a, b], seed: "11", until: 4, expected: 11, readable: { _, t in Int(t * 10) % 3 == 0 })
check(sameSize.suffix(10).allSatisfy { $0 == "11" }, "keeps #11 by his number and heading")

print("Running an approach")
let runner = Person(id: "11", number: 11, foot: { t in (0.2 + 0.18 * t, 0.3 + 0.03 * t) }, height: 0.26)
let blocker = Person(id: "15", number: 15, foot: { _ in (0.7, 0.36) }, height: 0.25)
let approach = run([runner, blocker], seed: "11", until: 2.5, expected: 11,
                   visible: { p, t in p.id != "11" || t < 1.0 || t > 1.4 })
check(approach.suffix(5).allSatisfy { $0 == "11" }, "picks him up again after a dropout mid-run")
check(!approach.contains("15"), "doesn't jump to a still player while he's missing")

print("Numbers")
var follower = PlayerFollower(seed: eleven.box(at: 0), time: 0, aspect: aspect, number: 7)
_ = follower.read(11, at: 0.2)
_ = follower.read(11, at: 0.7)
check(follower.number == 11 && follower.numberConfirmed, "adopts the number read on them when the card's number never shows")
var slid = PlayerFollower(seed: eleven.box(at: 0), time: 0, aspect: aspect, number: 11)
_ = slid.read(11, at: 0.5)
slid.update(twelve.box(at: 1), at: 1)
let first = slid.read(12, at: 1)
let second = slid.read(12, at: 1.5)
check(!first && second, "two reads of another number mean it's following the wrong player")
slid.rewind()
check(slid.lastSeen == 0.5 && slid.box == eleven.box(at: 0), "rewinds to the last time it saw #11")
let gated = slid.gate([twelve.box(at: 2), eleven.box(at: 2)], at: 2)
check(slid.choose(gated, numbers: [0: 12]) == 1, "then picks #11, never the number it slid onto")

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)

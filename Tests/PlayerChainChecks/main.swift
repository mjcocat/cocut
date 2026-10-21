import Foundation

// Synthetic clips for PlayerChain: the situations that broke frame-by-frame following.
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok  \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}
let aspect = 16.0 / 9.0
let fps = 15.0

/// Someone in the clip: where their head is and how tall they look at time t.
struct Player {
    var id: String
    var number: Int
    var head: (Double) -> (x: Double, y: Double)
    var height: Double
}

/// Builds frames, runs the chain from a spotlight on `seed` at the start, and says who it
/// followed in each frame (nil for gaps).
func run(_ players: [Player], seed: String, duration: Double, number: Int?,
         visible: (Player, Double) -> Bool = { _, _ in true },
         readable: (Player, Double) -> Bool = { _, _ in false },
         clicks: [(time: Double, id: String)] = []) -> [String?] {
    var frames: [PlayerChain.Frame] = []
    var who: [[String]] = []
    for k in 0...Int(duration * fps) {
        let t = Double(k) / fps
        let shown = players.filter { visible($0, t) }
        frames.append(.init(time: t, people: shown.map { p in
            let h = p.head(t), w = p.height * 0.4 / aspect
            return PlayerChain.Person(x: h.x - w / 2, y: h.y - p.height, width: w, height: p.height,
                                      number: k % 4 == 0 && readable(p, t) ? p.number : nil)
        }))
        who.append(shown.map(\.id))
    }
    let s = players.first { $0.id == seed }!
    var anchors = [PlayerChain.Anchor(time: 0, x: s.head(0).x, y: s.head(0).y - s.height / 2, kind: .body)]
    for click in clicks {
        let p = players.first { $0.id == click.id }!
        anchors.append(.init(time: click.time, x: p.head(click.time).x, y: p.head(click.time).y, kind: .head))
    }
    let path = PlayerChain.follow(frames, anchors: anchors, number: number, aspect: aspect)
    return path.enumerated().map { k, person in
        guard let person else { return nil }
        return frames[k].people.firstIndex { $0.x == person.x && $0.y == person.y }.map { who[k][$0] }
    }
}

print("A teammate walks between the camera and the net")
let eleven = Player(id: "11", number: 11, head: { t in (0.45 + 0.03 * t, 0.66) }, height: 0.24)
let twelve = Player(id: "12", number: 12, head: { t in (0.15 + 0.25 * t, 0.58) }, height: 0.52)
let crossing = run([eleven, twelve], seed: "11", duration: 4, number: 11,
                   visible: { p, t in p.id != "11" || abs(twelve.head(t).x - eleven.head(t).x) > 0.07 })
check(!crossing.contains("12"), "never follows the bigger player in front")
check(crossing.suffix(10).allSatisfy { $0 == "11" }, "back on #11 after he passes")

print("Two players the same size cross at the net")
let a = Player(id: "11", number: 11, head: { t in (0.35 + 0.08 * t, 0.66) }, height: 0.24)
let b = Player(id: "30", number: 30, head: { t in (0.6 - 0.08 * t, 0.67) }, height: 0.24)
let same = run([a, b], seed: "11", duration: 4, number: 11, readable: { p, _ in p.id == "30" })
check(same.suffix(10).allSatisfy { $0 == "11" }, "ends on #11: the other player's number rules him out")
check(!same.contains("30"), "never on #30")

print("Spectators behind the net")
let runner = Player(id: "11", number: 11, head: { t in (0.3 + 0.1 * t, 0.66) }, height: 0.26)
let fans = (0..<6).map { i in Player(id: "fan\(i)", number: 0, head: { _ in (0.2 + 0.1 * Double(i), 0.70) }, height: 0.12) }
let watched = run([runner] + fans, seed: "11", duration: 4, number: 11,
                  visible: { p, t in p.id != "11" || t < 1.5 || t > 2.2 })
check(!watched.contains { $0?.hasPrefix("fan") == true }, "never settles on a spectator while he's missing")
check(watched.suffix(10).allSatisfy { $0 == "11" }, "picks him up again")

print("A click on his head")
let lost = run([a, b], seed: "11", duration: 4, number: nil, clicks: [(3.0, "11")])
check(lost[Int(3.0 * fps)] == "11" && lost.last == "11", "the clicked player is followed from the click on")

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)

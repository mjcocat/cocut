import Foundation

// Runs PlayerChain on people found in a real clip (JSON from a detector) and writes which person
// it followed in each frame, for drawing on the video:
//   test-player-chain detections.json out.json <time> <x> <y> [body|head] [number] [<time> <x> <y> <kind>]...
// Coordinates are Vision's (0...1, origin bottom-left).
let args = CommandLine.arguments
guard args.count >= 6 else {
    print("usage: detections.json out.json time x y [body|head] [number]")
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let width = json["width"] as! Double, height = json["height"] as! Double
let frames: [PlayerChain.Frame] = (json["frames"] as! [[String: Any]]).map { f in
    PlayerChain.Frame(time: f["time"] as! Double, people: (f["people"] as! [[String: Any]]).map { p in
        PlayerChain.Person(x: p["x"] as! Double, y: p["y"] as! Double, width: p["w"] as! Double, height: p["h"] as! Double,
                           look: (p["look"] as? [Double])?.map { Float($0) }, number: p["number"] as? Int)
    })
}
var anchors: [PlayerChain.Anchor] = []
var number: Int?
var i = 3
while i + 2 < args.count {
    let kind: PlayerChain.Anchor.Kind = (i + 3 < args.count && args[i + 3] == "head") ? .head : .body
    anchors.append(.init(time: Double(args[i])!, x: Double(args[i + 1])!, y: Double(args[i + 2])!, kind: kind))
    i += 3
    if i < args.count, args[i] == "head" || args[i] == "body" { i += 1 }
    if i < args.count, let n = Int(args[i]), !args[i].contains(".") { number = n; i += 1 }
}
// CHAIN_SET="perFrame distanceCost sizeCost gapCost reach reachPerSecond lookWeight"
if let set = ProcessInfo.processInfo.environment["CHAIN_SET"]?.split(separator: " ").compactMap({ Double($0) }), set.count >= 7 {
    PlayerChain.settings = .init(perFrame: set[0], distanceCost: set[1], sizeCost: set[2], gapCost: set[3],
                                 reach: set[4], reachPerSecond: set[5], lookWeight: set[6])
    if set.count >= 9 { PlayerChain.settings.joinCost = set[7]; PlayerChain.settings.joinSize = set[8] }
    if set.count >= 11 { PlayerChain.settings.excludeAt = set[9]; PlayerChain.settings.otherCost = set[10] }
    if set.count >= 12 { PlayerChain.settings.chunkFrames = Int(set[11]) }
}
if ProcessInfo.processInfo.environment["CHAIN_DEBUG"] != nil { PlayerChain.debug = { print($0) } }
let started = Date()
let path = PlayerChain.follow(frames, anchors: anchors, number: number, aspect: width / height)
let pieces = PlayerChain.tracklets(frames, aspect: width / height)
print("\(frames.count) frames, \(pieces.count) pieces, followed in \(path.compactMap { $0 }.count) frames,",
      String(format: "%.2fs", Date().timeIntervalSince(started)))
let out: [[String: Any]] = zip(frames, path).map { f, p in
    var o: [String: Any] = ["time": f.time]
    if let p { o["box"] = [p.x, p.y, p.width, p.height] }
    return o
}
try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[2]))

// CHAIN_PIECES="t0 t1 x0 x1": list pieces starting in t0...t1 whose first head is in x0...x1.
if let spec = ProcessInfo.processInfo.environment["CHAIN_PIECES"]?.split(separator: " ").compactMap({ Double($0) }), spec.count == 4 {
    let summaries = pieces.map { PlayerChain.summarize($0, frames) }
    for (k, s) in summaries.enumerated() where s.startTime >= spec[0] && s.startTime <= spec[1] && s.first.head.x >= spec[2] && s.first.head.x <= spec[3] {
        print(String(format: "piece %d  %.2f-%.2fs  head %.3f,%.3f → %.3f,%.3f  h %.3f→%.3f  frames %d  numbers %@",
                     k, s.startTime, s.endTime, s.first.head.x, s.first.head.y, s.last.head.x, s.last.head.y,
                     s.first.height, s.last.height, s.frames, "\(s.numbers)"))
    }
    let a = summaries[178]
    for (k, s) in summaries.enumerated() where s.startTime >= spec[0] && s.startTime <= spec[1] && s.first.head.x >= spec[2] && s.first.head.x <= spec[3] {
        print("link 178 →", k, PlayerChain.link(a, s, aspect: width / height).map { String(format: "%.2f", $0) } ?? "no")
    }
}

// The 9:16 camera from what was followed, written next to the path (out.json → out.camera.json),
// so tests can check the player is in the phone frame, not just in the right box.
let sightings = zip(frames, path).compactMap { f, p in
    p.map { CameraPlanner.Sighting(time: f.time, x: $0.center.x, y: 1 - $0.center.y) }
}
let window = CameraPlanner.window(picture: (width, height), output: (1080, 1920))
let camera = CameraPlanner.plan(sightings: sightings, start: frames.first?.time ?? 0, end: frames.last?.time ?? 0,
                                window: window)
let cameraOut: [[String: Double]] = frames.map { f in
    let c = camera.center(at: f.time)
    return ["time": f.time, "x": c.x, "width": window.width]
}
try JSONSerialization.data(withJSONObject: cameraOut).write(to: URL(fileURLWithPath: args[2].replacingOccurrences(of: ".json", with: ".camera.json")))

// CHAIN_GT=gt.json: for each marked head, the piece it's in (span, frames) — to see how
// fragmented the player's pieces are.
if let gtPath = ProcessInfo.processInfo.environment["CHAIN_GT"],
   let gt = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: gtPath))) as? [String: [Double]] {
    var pieceOf: [[Int]] = frames.map { Array(repeating: -1, count: $0.people.count) }
    for (k, piece) in pieces.enumerated() { for m in piece.members { pieceOf[m.frame][m.person] = k } }
    for (t, g) in gt.sorted(by: { Double($0.key)! < Double($1.key)! }) {
        let f = frames.indices.min { abs(frames[$0].time - Double(t)!) < abs(frames[$1].time - Double(t)!) }!
        let hit = frames[f].people.indices.filter { i in
            let q = frames[f].people[i]
            return abs(q.head.x - g[0]) < max(0.04, q.width * 0.6) && q.head.y - g[1] > -q.height * 0.25 && q.head.y - g[1] < q.height * 0.45
        }
        if let i = hit.first {
            let k = pieceOf[f][i], s = PlayerChain.summarize(pieces[k], frames)
            print(String(format: "%5@  piece %3d  %.2f-%.2fs  %d frames  numbers %@", t, k, s.startTime, s.endTime, s.frames, "\(s.numbers)"))
        } else {
            print(String(format: "%5@  not found", t))
        }
    }
}

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok  \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}
let window9x16 = CameraPlanner.window(picture: (1920, 1080), output: (1080, 1920))
let window4x5 = CameraPlanner.window(picture: (1920, 1080), output: (1080, 1350))

print("Window sizes")
check(abs(window9x16.width - 0.3164) < 0.001 && window9x16.height == 1, "9:16 from 16:9 keeps 31.6% of the width, full height (\(window9x16))")
check(abs(window4x5.width - 0.45) < 0.001 && window4x5.height == 1, "4:5 from 16:9 keeps 45% of the width (\(window4x5))")
let tall = CameraPlanner.window(picture: (1080, 1920), output: (1080, 1350))
check(tall.width == 1 && abs(tall.height - 0.703125) < 0.001, "4:5 from a phone video keeps the full width, part of the height (\(tall))")

func sightings(_ duration: Double, fps: Double = 10, _ f: (Double) -> (Double, Double)?) -> [CameraPlanner.Sighting] {
    stride(from: 0.0, through: duration, by: 1 / fps).compactMap { t in f(t).map { .init(time: t, x: $0.0, y: $0.1) } }
}

print("Standing still")
let still = CameraPlanner.plan(sightings: sightings(4) { _ in (0.7, 0.5) }, start: 0, end: 4, window: window9x16)
check(still.xs.allSatisfy { abs($0 - 0.7) < 1e-9 }, "a still player gets a still frame on them")
check(still.ys.allSatisfy { $0 == 0.5 }, "full-height window never moves up or down")

print("Tracker wobble")
var seed: UInt64 = 42
func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
let wobble = CameraPlanner.plan(sightings: sightings(6) { _ in (0.5 + noise() * 0.04, 0.5) }, start: 0, end: 6, window: window9x16)
let spread = (wobble.xs.max() ?? 0) - (wobble.xs.min() ?? 0)
check(spread < 0.005, "±2% jitter leaves the frame steady (moved \(String(format: "%.4f", spread)))")

print("Running across the court")
let run = CameraPlanner.plan(sightings: sightings(6) { t in (0.2 + 0.1 * t, 0.5) }, start: 0, end: 6, window: window9x16)
var worst = 0.0
for i in run.xs.indices {
    let t = run.start + Double(i) * run.step
    worst = max(worst, abs((0.2 + 0.1 * min(t, 6)) - run.xs[i]))
}
check(worst < window9x16.width / 2, "player stays inside the frame the whole run (worst offset \(String(format: "%.3f", worst)), half frame \(String(format: "%.3f", window9x16.width / 2)))")
let maxJump = zip(run.xs, run.xs.dropFirst()).map { abs($1 - $0) }.max() ?? 0
check(maxJump <= 1.2 * 0.1 + 1e-9, "never faster than the speed cap (\(String(format: "%.4f", maxJump)) per 0.1s)")
let accel = zip(zip(run.xs, run.xs.dropFirst()), run.xs.dropFirst(2)).map { abs(($1 - $0.1) - ($0.1 - $0.0)) }.max() ?? 0
check(accel < 0.01, "moves ease in and out, no jerks (max change in speed \(String(format: "%.4f", accel)))")

print("Edges of the picture")
let edge = CameraPlanner.plan(sightings: sightings(3) { _ in (0.02, 0.5) }, start: 0, end: 3, window: window9x16)
check(edge.xs.allSatisfy { abs($0 - window9x16.width / 2) < 1e-9 }, "a player at the edge pins the frame to the edge, never past it")

print("Lost for a while")
let gap = CameraPlanner.plan(sightings: sightings(6) { t in (t < 2 || t > 4) ? (0.3 + 0.08 * t, 0.5) : nil }, start: 0, end: 6, window: window9x16)
check(gap.xs.allSatisfy { $0.isFinite }, "no gaps or NaNs while the player is lost")
let gapJump = zip(gap.xs, gap.xs.dropFirst()).map { abs($1 - $0) }.max() ?? 0
check(gapJump < 0.05, "glides across the gap (largest step \(String(format: "%.4f", gapJump)))")

print("Never seen")
let none = CameraPlanner.plan(sightings: [], start: 1, end: 3, window: window9x16, fallback: (0.62, 0.5))
check(none.xs.allSatisfy { $0 == 0.62 }, "falls back to the spotlight spot")

print("Clip times")
let late = CameraPlanner.plan(sightings: sightings(2) { _ in (0.6, 0.5) }.map { .init(time: $0.time + 10, x: $0.x, y: $0.y) }, start: 10, end: 12, window: window9x16)
check(abs(late.center(at: 11).x - 0.6) < 1e-9, "paths use the clip's own seconds (trimmed clips)")
let ramp = CameraPath(start: 0, step: 1, xs: [0.2, 0.4], ys: [0.5, 0.5])
check(abs(ramp.center(at: 0.5).x - 0.3) < 1e-9 && ramp.center(at: -1).x == 0.2 && ramp.center(at: 9).x == 0.4, "center(at:) eases between samples and holds at the ends")
check(CameraPath.fixed(x: 0.3, y: 0.5).center(at: 100).x == 0.3, "a fixed path stays put")

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)

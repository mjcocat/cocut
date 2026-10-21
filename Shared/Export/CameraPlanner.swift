import Foundation

/// Where the phone frame looks during a clip: the frame's center over time, in the clip's
/// picture (0...1 across and down, top-left origin), sampled evenly in the clip's own seconds.
struct CameraPath: Codable, Sendable, Equatable {
    /// Clip time of the first sample, and the time between samples.
    var start: Double
    var step: Double
    var xs: [Double]
    var ys: [Double]

    /// A frame that stays put.
    static func fixed(x: Double, y: Double, start: Double = 0) -> CameraPath {
        CameraPath(start: start, step: 1, xs: [x], ys: [y])
    }

    /// The center at `time` (clip seconds), eased between samples; held before and after.
    func center(at time: Double) -> (x: Double, y: Double) {
        guard let firstX = xs.first, let firstY = ys.first else { return (0.5, 0.5) }
        let n = min(xs.count, ys.count)
        let f = step > 0 ? (time - start) / step : 0
        guard f > 0 else { return (firstX, firstY) }
        let i = Int(f)
        guard i < n - 1 else { return (xs[n - 1], ys[n - 1]) }
        let t = f - Double(i)
        return (xs[i] + (xs[i + 1] - xs[i]) * t, ys[i] + (ys[i + 1] - ys[i]) * t)
    }
}

/// Where the phone frame looks at one moment, set by hand in the phone frame editor (clip
/// seconds; center as picture fractions, top-left origin).
struct PhoneKey: Codable, Hashable, Sendable {
    var time: Double
    var x: Double
    var y: Double
}

/// Where the player's head is at one moment, clicked in the phone frame editor so following
/// them starts (or starts over) there (clip seconds; picture fractions, top-left origin).
struct PlayerMark: Codable, Hashable, Sendable {
    var time: Double
    var x: Double
    var y: Double
}

/// Turns where a player was seen into calm camera movement, like a good camera operator: the
/// frame holds still while the player moves a little, follows smoothly when they move more,
/// eases in and out of moves, never whips faster than a set speed, and never shows past the
/// edge of the picture. Plain math, no video, so it's tested on its own.
enum CameraPlanner {
    /// The player's center in one frame (picture fractions, top-left origin).
    struct Sighting: Equatable {
        var time: Double
        var x: Double
        var y: Double
    }

    struct Settings {
        /// Samples per second of the path.
        var step = 0.1
        /// Smoothing of the raw positions (seconds), which steadies the tracker's wobble.
        var steadying = 0.35
        /// How far the player may drift from the center before the frame moves, as a fraction of
        /// the frame's size.
        var deadZone = 0.18
        /// Easing of the frame's own moves (seconds).
        var easing = 0.3
        /// Fastest the frame moves, in picture widths (or heights) per second.
        var maxSpeed = 1.2
    }

    /// The path for a clip running from `start` to `end` (clip seconds). `window` is the phone
    /// frame's size as a fraction of the picture (1 on an axis means it never moves that way).
    /// With no sightings, the frame stays at `fallback`.
    static func plan(sightings: [Sighting], start: Double, end: Double,
                     window: (width: Double, height: Double),
                     fallback: (x: Double, y: Double) = (0.5, 0.5),
                     settings: Settings = Settings()) -> CameraPath {
        let step = settings.step
        let count = max(2, Int(((end - start) / step).rounded(.up)) + 1)
        let times = (0..<count).map { start + Double($0) * step }
        let seen = sightings.filter { $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }

        func axis(_ value: (Sighting) -> Double, size: Double, fallback: Double) -> [Double] {
            let lo = min(0.5, size / 2), hi = max(0.5, 1 - size / 2)
            func bounded(_ v: Double) -> Double { min(hi, max(lo, v)) }
            guard !seen.isEmpty else { return Array(repeating: bounded(fallback), count: count) }
            // 1. Where the player is at each sample: between sightings, in a straight line.
            let raw = times.map { interpolate(seen, at: $0, value) }
            // 2. Steady the tracker's wobble.
            let steady = gaussian(raw, sigma: settings.steadying / step)
            // 3. Hold still until the player drifts out of the dead zone, then follow just enough.
            let zone = settings.deadZone * size
            var held = [bounded(steady[0])]
            for v in steady.dropFirst() {
                let last = held[held.count - 1]
                let d = v - last
                held.append(abs(d) > zone ? bounded(last + d - (d > 0 ? zone : -zone)) : last)
            }
            // 4. Ease the moves, cap the speed, and keep the frame inside the picture.
            let eased = gaussian(held, sigma: settings.easing / step)
            let maxStep = settings.maxSpeed * step
            var path = [bounded(eased[0])]
            for v in eased.dropFirst() {
                let last = path[path.count - 1]
                path.append(bounded(last + min(maxStep, max(-maxStep, v - last))))
            }
            return path
        }

        let xs = axis({ $0.x }, size: window.width, fallback: fallback.x)
        let ys = axis({ $0.y }, size: window.height, fallback: fallback.y)
        return CameraPath(start: start, step: step, xs: xs, ys: ys)
    }

    /// The path through keys set by hand: held before the first and after the last, gliding
    /// from one to the next with an eased start and stop. Keys laid down close together (by
    /// steering while the clip plays) run straight through, lightly smoothed.
    static func keyframed(_ keys: [PhoneKey], start: Double, end: Double,
                          window: (width: Double, height: Double), step: Double = 0.1) -> CameraPath {
        let sorted = keys.filter { $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
        let count = max(2, Int(((end - start) / step).rounded(.up)) + 1)
        let times = (0..<count).map { start + Double($0) * step }
        func axis(_ value: (PhoneKey) -> Double, size: Double) -> [Double] {
            let lo = min(0.5, size / 2), hi = max(0.5, 1 - size / 2)
            guard let first = sorted.first, let last = sorted.last else { return Array(repeating: 0.5, count: count) }
            let raw = times.map { t -> Double in
                if t <= first.time { return value(first) }
                if t >= last.time { return value(last) }
                guard let i = sorted.lastIndex(where: { $0.time <= t }), i + 1 < sorted.count else { return value(last) }
                let a = sorted[i], b = sorted[i + 1]
                let span = b.time - a.time
                guard span > 0 else { return value(b) }
                var f = (t - a.time) / span
                // A deliberate move between two keys eases in and out; steering keys don't.
                if span > 0.6 { f = f * f * (3 - 2 * f) }
                return value(a) + (value(b) - value(a)) * f
            }
            return gaussian(raw, sigma: 0.12 / step).map { min(hi, max(lo, $0)) }
        }
        return CameraPath(start: start, step: step, xs: axis({ $0.x }, size: window.width),
                          ys: axis({ $0.y }, size: window.height))
    }

    /// The value at `time`: held before the first sighting and after the last, straight lines
    /// between (so a few frames where the player was lost become a glide).
    static func interpolate(_ seen: [Sighting], at time: Double, _ value: (Sighting) -> Double) -> Double {
        guard let first = seen.first, let last = seen.last else { return 0.5 }
        if time <= first.time { return value(first) }
        if time >= last.time { return value(last) }
        var lo = 0, hi = seen.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if seen[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = seen[lo], b = seen[hi]
        let span = b.time - a.time
        guard span > 0 else { return value(a) }
        return value(a) + (value(b) - value(a)) * (time - a.time) / span
    }

    /// Gaussian smoothing over `sigma` samples, holding the ends.
    static func gaussian(_ values: [Double], sigma: Double) -> [Double] {
        guard sigma > 0.01, values.count > 2 else { return values }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let n = values.count
        return (0..<n).map { i in
            var sum = 0.0, total = 0.0
            for (k, w) in weights.enumerated() {
                let j = min(n - 1, max(0, i + k - radius))
                sum += values[j] * w
                total += w
            }
            return sum / total
        }
    }

    /// The phone frame's size as a fraction of a picture: the full height and a slice of the
    /// width for a wide picture (or the full width and a slice of the height for a tall one).
    static func window(picture: (width: Double, height: Double), output: (width: Double, height: Double))
        -> (width: Double, height: Double) {
        guard picture.width > 0, picture.height > 0, output.width > 0, output.height > 0 else { return (1, 1) }
        let pictureAspect = picture.width / picture.height, outputAspect = output.width / output.height
        if pictureAspect > outputAspect {
            return (outputAspect / pictureAspect, 1)
        } else {
            return (1, pictureAspect / outputAspect)
        }
    }
}

import AVFoundation
import SwiftUI

/// Frame a clip for phone reels by hand. The whole picture is on the left with the phone frame
/// drawn on it; the phone-shaped result is on the right, live. Drag the frame (or the phone
/// picture) to move it: paused, that sets a key at the playhead; while playing, it steers. The
/// export glides from key to key.
struct PhoneFrameEditor: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let url: URL
    let onDone: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    /// The playhead, in clip seconds.
    @State private var time: Double = 0
    @State private var playing = false
    @State private var framing: PhoneFraming = .automatic
    @State private var keys: [PhoneKey] = []
    @State private var shape: ReelShape = .vertical
    /// The upright picture's size in pixels (after the clip's crop).
    @State private var picture: CGSize?
    /// Following the spotlighted player, for Automatic.
    @State private var followPath: CameraPath?
    @State private var following = false
    @State private var drag: DragState?
    @State private var scrubbing = false

    private struct DragState {
        var center: CGPoint
        var startTime: Double
        /// Keys laid down by this drag (while playing), which it may replace as it goes.
        var laid: Set<Double> = []
        var lastLaid = -Double.infinity
    }

    private var library: ClipLibrary { model.library }
    private var options: ExportOptions { model.exporter.options }
    private var start: Double { clip.trimStartSeconds }
    private var end: Double { clip.trimEndSeconds }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.l) {
                wholePicture
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                phonePreview
            }
            .padding([.horizontal, .top], Design.Space.l)
            .padding(.bottom, Design.Space.s)

            timeline
                .padding(.horizontal, Design.Space.l)
                .padding(.bottom, Design.Space.m)

            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .task(id: clip.id) { await load() }
        .task(id: shape) { await follow() }
        .onDisappear { teardown() }
    }

    // MARK: Framing math

    /// The phone frame's size as a fraction of the picture.
    private var window: (width: Double, height: Double) {
        guard let picture else { return (1, 1) }
        return CameraPlanner.window(picture: (Double(picture.width), Double(picture.height)),
                                    output: (Double(shape.phoneSize.width), Double(shape.phoneSize.height)))
    }

    /// Keeps a center where the whole frame stays inside the picture.
    private func bounded(_ p: CGPoint) -> CGPoint {
        let w = window
        func axis(_ v: CGFloat, _ size: Double) -> CGFloat {
            let lo = min(0.5, size / 2), hi = max(0.5, 1 - size / 2)
            return CGFloat(min(hi, max(lo, Double(v))))
        }
        return CGPoint(x: axis(p.x, w.width), y: axis(p.y, w.height))
    }

    /// What Automatic does for this clip.
    private var automaticIsWhole: Bool {
        !(options.followSpotlight && clip.spotlight != nil) && options.unspotlitFraming == .wholePicture
    }

    private var showsWhole: Bool {
        framing == .wholePicture || (framing == .automatic && automaticIsWhole)
    }

    /// Where the frame looks at `t`; nil when the whole picture is shown.
    private func center(at t: Double) -> CGPoint? {
        switch framing {
        case .wholePicture:
            return nil
        case .centered:
            return bounded(CGPoint(x: 0.5, y: 0.5))
        case .custom:
            guard !keys.isEmpty else { return bounded(CGPoint(x: 0.5, y: 0.5)) }
            let c = CameraPlanner.keyframed(keys, start: start, end: end, window: window).center(at: t)
            return CGPoint(x: c.x, y: c.y)
        case .automatic:
            if automaticIsWhole { return nil }
            if options.followSpotlight, let spot = clip.spotlight {
                if let followPath {
                    let c = followPath.center(at: t)
                    return CGPoint(x: c.x, y: c.y)
                }
                return bounded(CGPoint(x: spot.x, y: spot.y))
            }
            return bounded(CGPoint(x: 0.5, y: 0.5))
        }
    }

    /// The key nearest the playhead, if it's close enough to count as "on" it.
    private var keyAtPlayhead: PhoneKey? {
        guard framing == .custom else { return nil }
        return keys.filter { abs($0.time - time) < 0.15 }.min { abs($0.time - time) < abs($1.time - time) }
    }

    // MARK: Editing

    /// Moves the frame to `p` at the playhead: a key there (paused), or steering (playing).
    private func place(_ p: CGPoint) {
        let p = bounded(p)
        if framing != .custom { becomeCustom() }
        let key = PhoneKey(time: time, x: Double(p.x), y: Double(p.y))
        if playing, var d = drag {
            // Steering: replace what was there between where the drag began and now.
            keys.removeAll { $0.time >= d.startTime - 0.01 && $0.time <= time + 0.01 && !d.laid.contains($0.time) }
            if time - d.lastLaid >= 0.2 {
                keys.append(key)
                d.laid.insert(key.time)
                d.lastLaid = time
            } else if let i = keys.firstIndex(where: { $0.time == d.lastLaid }) {
                keys[i].x = key.x
                keys[i].y = key.y
            }
            drag = d
        } else {
            keys.removeAll { abs($0.time - time) < 0.15 }
            keys.append(key)
        }
        keys.sort { $0.time < $1.time }
    }

    /// Switching to Custom starts from what's showing: the followed path (as keys every half
    /// second) when following, otherwise the keys already set (or none).
    private func becomeCustom() {
        if framing == .automatic, let followPath, !automaticIsWhole {
            keys = stride(from: start, through: end, by: 0.5).map { t in
                let c = followPath.center(at: t)
                return PhoneKey(time: t, x: c.x, y: c.y)
            }
        }
        framing = .custom
    }

    private func deleteKey() {
        guard let key = keyAtPlayhead else { return }
        keys.removeAll { $0 == key }
    }

    private func clearKeys() {
        keys = []
        framing = .automatic
    }

    private func save() {
        player?.pause()
        let final: PhoneFraming = framing == .custom && keys.isEmpty ? .automatic : framing
        library.setPhoneFrame(final, keys: keys, for: clip.id)
        onDone()
    }

    // MARK: Player

    private func load() async {
        framing = clip.phoneFraming ?? .automatic
        keys = clip.phoneKeys ?? []
        if framing == .custom, keys.isEmpty { framing = .automatic }
        shape = options.shape.isPhone ? options.shape : .vertical
        time = start
        picture = await ReelExporter.pictureSize(url: url, crop: clip.unitCrop)

        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        if let crop = clip.cropRect {
            item.videoComposition = PlayerView.cropComposition(for: item.asset, crop: crop)
        }
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
            MainActor.assumeIsolated {
                guard !scrubbing else { return }
                time = min(end, max(start, t.seconds))
                playing = player.rate != 0
                // Hold the last key a drag laid while the clip keeps going.
                if playing, let d = drag, d.lastLaid > -Double.infinity, time - d.lastLaid >= 0.2,
                   let last = keys.first(where: { $0.time == d.lastLaid }) {
                    place(CGPoint(x: last.x, y: last.y))
                }
            }
        }
        self.player = player
    }

    private func follow() async {
        guard options.followSpotlight, let spot = clip.spotlight else { followPath = nil; return }
        following = true
        let path = await ReelExporter.followPath(
            clip: clip, url: url, spot: spot, renderSize: shape.phoneSize,
            cacheDirectory: library.rootDirectory.appending(path: "Framing", directoryHint: .isDirectory))
        // A newer run (the shape changed) takes over.
        guard !Task.isCancelled else { return }
        followPath = path
        following = false
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
            playing = false
        } else {
            if time >= end - 0.05 { seek(to: start, exact: true) }
            player.play()
            playing = true
        }
    }

    private func seek(to t: Double, exact: Bool) {
        let t = min(end, max(start, t))
        time = t
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 20)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func jump(next: Bool) {
        let times = keys.map(\.time)
        let target = next ? times.filter { $0 > time + 0.05 }.min() : times.filter { $0 < time - 0.05 }.max()
        if let target { seek(to: target, exact: true) }
    }

    // MARK: Views

    /// The picture's rect, fitted (letterboxed) in the available space.
    private func fitted(_ size: CGSize) -> CGRect {
        guard let picture, picture.width > 0, picture.height > 0 else { return .zero }
        let s = min(size.width / picture.width, size.height / picture.height)
        let w = picture.width * s, h = picture.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private var wholePicture: some View {
        GeometryReader { geo in
            let rect = fitted(geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                if let player, rect.width > 0 {
                    PlayerLayerView(player: player)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    frameOverlay(in: rect)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard rect.width > 0 else { return }
                    func fraction(_ p: CGPoint) -> CGPoint {
                        CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
                    }
                    if drag == nil {
                        // Grab the frame, or (clicking outside it) bring it to the click.
                        let current = center(at: time) ?? bounded(fraction(value.startLocation))
                        let w = window
                        let grabbed = abs(fraction(value.startLocation).x - current.x) <= w.width / 2
                            && abs(fraction(value.startLocation).y - current.y) <= w.height / 2
                        drag = DragState(center: grabbed ? current : bounded(fraction(value.startLocation)), startTime: time)
                    }
                    guard let d = drag else { return }
                    place(CGPoint(x: d.center.x + value.translation.width / rect.width,
                                  y: d.center.y + value.translation.height / rect.height))
                }
                .onEnded { _ in drag = nil })
            .overlay(alignment: .top) {
                Text(hint)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .mediaFrame()
    }

    private var hint: String {
        if following { return "Following the player… (only the first time)" }
        if showsWhole { return "Whole picture: drag to frame it instead" }
        if playing { return "Drag while it plays to steer the frame" }
        return "Drag the frame, or click where it should look"
    }

    /// The phone frame on the whole picture: everything outside it dimmed.
    private func frameOverlay(in rect: CGRect) -> some View {
        let w = window
        let c = center(at: time) ?? CGPoint(x: 0.5, y: 0.5)
        let frame = CGRect(x: rect.minX + (c.x - w.width / 2) * rect.width,
                           y: rect.minY + (c.y - w.height / 2) * rect.height,
                           width: w.width * rect.width, height: w.height * rect.height)
        let whole = showsWhole
        let onKey = keyAtPlayhead != nil
        return Canvas { context, _ in
            if !whole {
                var dim = Path(rect)
                dim.addRect(frame)
                context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                context.stroke(Path(roundedRect: frame, cornerRadius: 6), with: .color(.white), lineWidth: 2.5)
            }
            // Keys at the playhead show as a filled marker at the frame's center.
            if onKey, !whole {
                let dot = CGRect(x: frame.midX - 6, y: frame.midY - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: dot), with: .color(.yellow))
            }
        }
        .allowsHitTesting(false)
    }

    /// The phone-shaped result, live: the picture moved and scaled so the frame fills it.
    private var phonePreview: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.black
                if let player, let picture, picture.width > 0 {
                    if let c = center(at: time) {
                        let w = window
                        let scale = size.width / (CGFloat(w.width) * picture.width)
                        let pw = picture.width * scale, ph = picture.height * scale
                        PlayerLayerView(player: player)
                            .frame(width: pw, height: ph)
                            .offset(x: size.width / 2 - c.x * pw, y: size.height / 2 - c.y * ph)
                    } else {
                        let s = min(size.width / picture.width, size.height / picture.height)
                        PlayerLayerView(player: player)
                            .frame(width: picture.width * s, height: picture.height * s)
                            .offset(x: (size.width - picture.width * s) / 2, y: (size.height - picture.height * s) / 2)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            // Dragging the phone picture pans it, like moving a photo under a frame.
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard let picture, picture.width > 0 else { return }
                    if drag == nil {
                        drag = DragState(center: center(at: time) ?? CGPoint(x: 0.5, y: 0.5), startTime: time)
                    }
                    guard let d = drag else { return }
                    let w = window
                    let perPoint = CGFloat(w.width) / size.width
                    let aspect = picture.width / picture.height
                    place(CGPoint(x: d.center.x - value.translation.width * perPoint,
                                  y: d.center.y - value.translation.height * perPoint * aspect))
                }
                .onEnded { _ in drag = nil })
        }
        .aspectRatio(shape.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Design.hairline, lineWidth: 1))
        .overlay(alignment: .bottom) {
            if showsWhole {
                Text("Blurred background in the export")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Phone preview")
        .layoutPriority(1)
    }

    private var timeline: some View {
        HStack(spacing: Design.Space.m) {
            Button(action: togglePlay) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(playing ? "Pause (Space)" : "Play (Space)")

            Text(Clip.format(time - start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let span = max(0.01, end - start)
                let x: (Double) -> CGFloat = { CGFloat(($0 - start) / span) * width }
                ZStack(alignment: .leading) {
                    Capsule().fill(Design.panelFill).frame(height: 6)
                    Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: max(0, x(time)), height: 6)
                    if framing == .custom {
                        ForEach(keys, id: \.self) { key in
                            Rectangle()
                                .fill(key == keyAtPlayhead ? Color.yellow : Color.primary.opacity(0.7))
                                .frame(width: 7, height: 7)
                                .rotationEffect(.degrees(45))
                                .offset(x: x(key.time) - 3.5)
                        }
                    }
                    Circle()
                        .fill(.white)
                        .shadow(radius: 1.5)
                        .frame(width: 14, height: 14)
                        .offset(x: x(time) - 7)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        player?.pause()
                        playing = false
                        seek(to: start + Double(value.location.x / max(1, width)) * span, exact: false)
                    }
                    .onEnded { value in
                        seek(to: start + Double(value.location.x / max(1, width)) * span, exact: true)
                        scrubbing = false
                    })
            }
            .frame(height: 22)

            Text(Clip.format(end - start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            ControlGroup {
                Button { jump(next: false) } label: { Image(systemName: "chevron.left") }
                    .help("Previous key")
                Button { jump(next: true) } label: { Image(systemName: "chevron.right") }
                    .help("Next key")
            }
            .disabled(framing != .custom || keys.isEmpty)
            .fixedSize()

            Button("Delete Key", systemImage: "minus.diamond", action: deleteKey)
                .labelStyle(.iconOnly)
                .disabled(keyAtPlayhead == nil)
                .help("Delete the key at the playhead")
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Framing", selection: Binding(
                get: { framing },
                set: { new in
                    if new == .custom, keys.isEmpty { becomeCustom() } else { framing = new }
                }
            )) {
                Text(clip.spotlight != nil && options.followSpotlight ? "Follow Player" : "Automatic").tag(PhoneFraming.automatic)
                Text("Centered").tag(PhoneFraming.centered)
                Text("Whole").tag(PhoneFraming.wholePicture)
                Text("Custom").tag(PhoneFraming.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Custom is what you drag; the others are set for you")

            Picker("Shape", selection: $shape) {
                Text("9:16").tag(ReelShape.vertical)
                Text("4:5").tag(ReelShape.portrait)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Preview as Phone 9:16 or Feed 4:5. Keys work for both.")

            if framing == .custom, !keys.isEmpty {
                Text("\(keys.count) \(keys.count == 1 ? "key" : "keys")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear", action: clearKeys)
                    .help("Remove every key and go back to Automatic")
            }

            Spacer()

            Button("Cancel", action: { player?.pause(); onDone() })
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A bare AVPlayerLayer, so the same player can show in two places at once.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resize
            playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

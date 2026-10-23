import AVFoundation
import SwiftUI

/// Place the spotlight ring: pick the moment (the first frame, or later when the athlete is
/// hidden at the start), click the athlete, drag to adjust, size with the slider. Return saves
/// and moves to the next clip.
struct SpotlightEditor: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let url: URL
    let hasNext: Bool
    let onSave: (_ spotlight: Spotlight?, _ next: Bool) -> Void
    let onCancel: () -> Void

    @State private var image: CGImage?
    @State private var spot: Spotlight = .standard
    @State private var placed = false
    /// The moment shown and spotlighted (seconds in the video).
    @State private var time: Double = 0
    @State private var ready = false

    private var start: Double { clip.trimStartSeconds }
    private var end: Double { max(clip.trimEndSeconds, clip.trimStartSeconds + 0.01) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let picture = fitted(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: picture.width, height: picture.height)
                            .offset(x: picture.minX, y: picture.minY)
                        ring(in: picture)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard picture.width > 0 else { return }
                    spot.x = min(1, max(0, (value.location.x - picture.minX) / picture.width))
                    spot.y = min(1, max(0, (value.location.y - picture.minY) / picture.height))
                    placed = true
                })
                .overlay(alignment: .top) {
                    Text(placed ? (time - start < 0.05 ? "Drag to adjust. The reel opens on this frame with the ring around them."
                                                      : "Drag to adjust. The reel plays up to here, then holds it with the ring around them.")
                                : "Click your athlete. Hidden behind someone? Slide to a moment where you can see them.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }

            if end - start > 0.3 {
                HStack(spacing: 10) {
                    Text("Moment").foregroundStyle(.secondary)
                    Button { step(-1 / 15) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .help("Back a little (←)")
                    Slider(value: $time, in: start...end)
                    Button { step(1 / 15) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .help("On a little (→)")
                    Text(String(format: "%.1f s", time - start))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Button("First Frame") { time = start }
                        .disabled(time - start < 0.05)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .background(.bar)
            }

            HStack(spacing: 14) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Slider(value: $spot.radius, in: 0.04...0.3)
                    .frame(width: 140)
                    .help("Size")
                SpotlightStyleControls()
                Spacer()
                if clip.spotlight != nil {
                    Button("Remove", role: .destructive) { onSave(nil, false) }
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if hasNext {
                    Button("Save") { onSave(saved, false) }
                    Button("Save & Next") { onSave(saved, true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("Save and go to the next clip (Return)")
                } else {
                    Button("Save") { onSave(saved, false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .task(id: clip.id) {
            ready = false
            // A clip without one starts from the last ring (its size carries over with Save & Next).
            if let existing = clip.spotlight {
                spot = existing
                placed = true
            }
            time = clip.spotlight?.moment(in: clip) ?? start
            image = await Self.firstFrame(url: url, at: time, crop: clip.unitCrop)
            ready = true
        }
        // The frame at the moment, as the slider moves (the latest position wins).
        .task(id: "\(clip.id)-\(Int((time * 30).rounded()))") {
            guard ready else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            if let frame = await Self.firstFrame(url: url, at: time, crop: clip.unitCrop), !Task.isCancelled {
                image = frame
            }
        }
    }

    /// The spotlight with its moment (none when it's the clip's first frame).
    private var saved: Spotlight {
        var s = spot
        s.time = time - start < 0.05 ? nil : time
        return s
    }

    private func step(_ seconds: Double) {
        time = min(end, max(start, time + seconds))
    }

    /// The picture's rect, fitted (letterboxed) in the available space.
    private func fitted(in size: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = min(size.width / iw, size.height / ih)
        let w = iw * s, h = ih * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func ring(in picture: CGRect) -> some View {
        let c = CGPoint(x: picture.minX + spot.x * picture.width, y: picture.minY + spot.y * picture.height)
        let r = spot.radius * picture.height
        let options = model.exporter.options
        let rx = r * options.spotlightShape.aspect
        let accent = options.spotlightColor.flatMap { Color(hex: $0) } ?? model.profile.profile.accentColor
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var dim = Path(CGRect(origin: .zero, size: size))
                dim.addEllipse(in: CGRect(x: c.x - rx * 1.15, y: c.y - r * 1.15, width: rx * 2.3, height: r * 2.3))
                context.fill(dim, with: .color(.black.opacity(placed ? 0.5 : 0.25)), style: FillStyle(eoFill: true))
                context.stroke(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - r, width: rx * 2, height: r * 2)),
                               with: .color(accent), lineWidth: max(3, picture.height / 180))
            }
            .allowsHitTesting(false)
        }
    }

    /// The clip's first frame (at its trim start), cropped like the clip.
    static func firstFrame(url: URL, at seconds: Double, crop: CGRect?) async -> CGImage? {
        await VideoFrames.firstFrame(url: url, at: seconds, crop: crop)
    }
}

/// Shape and color of every spotlight in the reel (saved with the export settings).
struct SpotlightStyleControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var exporter = model.exporter
        HStack(spacing: 10) {
            Picker("Shape", selection: $exporter.options.spotlightShape) {
                ForEach(SpotlightShape.allCases) { shape in
                    Image(systemName: shape == .oval ? "capsule.portrait" : "circle").tag(shape)
                        .help(shape.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
            .help("Oval fits a standing player; circle is classic")

            ColorPicker("Color", selection: Binding(
                get: { exporter.options.spotlightColor.flatMap { Color(hex: $0) } ?? model.profile.profile.accentColor },
                set: { exporter.options.spotlightColor = $0.hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Spotlight color")

            if exporter.options.spotlightColor != nil {
                Button("Team Color") { exporter.options.spotlightColor = nil }
                    .controlSize(.small)
                    .help("Use the Player Card's team color")
            }
        }
    }
}

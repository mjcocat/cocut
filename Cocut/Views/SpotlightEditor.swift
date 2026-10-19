import AVFoundation
import SwiftUI

/// Place the spotlight ring on a clip's first frame: click the athlete, drag to adjust, size
/// with the slider. Return saves and moves to the next clip.
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
                    Text(placed ? "Drag to adjust. The reel holds this frame with the ring around them." : "Click your athlete")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Slider(value: $spot.radius, in: 0.04...0.3)
                    .frame(width: 160)
                    .help("Ring size")
                Spacer()
                if clip.spotlight != nil {
                    Button("Remove", role: .destructive) { onSave(nil, false) }
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if hasNext {
                    Button("Save") { onSave(spot, false) }
                    Button("Save & Next") { onSave(spot, true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("Save and go to the next clip (Return)")
                } else {
                    Button("Save") { onSave(spot, false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .task(id: clip.id) {
            if let existing = clip.spotlight {
                spot = existing
                placed = true
            }
            image = await Self.firstFrame(url: url, at: clip.trimStartSeconds, crop: clip.unitCrop)
        }
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
        let accent = model.profile.profile.accentColor
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var dim = Path(CGRect(origin: .zero, size: size))
                dim.addEllipse(in: CGRect(x: c.x - r * 1.15, y: c.y - r * 1.15, width: r * 2.3, height: r * 2.3))
                context.fill(dim, with: .color(.black.opacity(placed ? 0.5 : 0.25)), style: FillStyle(eoFill: true))
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(accent), lineWidth: max(3, picture.height / 180))
            }
            .allowsHitTesting(false)
        }
    }

    /// The clip's first frame (at its trim start), cropped like the clip.
    static func firstFrame(url: URL, at seconds: Double, crop: CGRect?) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let full = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        guard let crop else { return full }
        let w = CGFloat(full.width), h = CGFloat(full.height)
        let rect = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
        return full.cropping(to: rect) ?? full
    }
}

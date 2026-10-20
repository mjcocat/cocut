import AVFoundation
import SwiftUI

/// Mark the air above your court on a frame of the match, so Find Rallies only watches for the
/// ball there: neighboring courts, the crowd and players walking between points are ignored.
struct CourtAreaScreen: View {
    let url: URL
    /// Called with the marked area (unit coordinates, top-left origin), or nil for automatic.
    let onDone: (CGRect?) -> Void
    let onCancel: () -> Void

    @State private var frame: CGImage?
    @State private var area: CGRect = RallyFinder.savedCourtArea ?? CourtAreaScreen.defaultArea
    /// The area when the current drag started.
    @State private var dragStart: CGRect?
    @AppStorage(RallyDetector.quickReadingKey) private var quickReading = false

    static let defaultArea = CGRect(x: 0.12, y: 0.04, width: 0.76, height: 0.24)
    private static let minSide: CGFloat = 0.05

    private enum Handle { case move, topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Drag the box over the air **above your court**: from the top of the net up, between the two antennas. Keep other courts and the crowd out of it.")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { geo in
                    let picture = fitted(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        if let frame {
                            Image(decorative: frame, scale: 1)
                                .resizable()
                                .frame(width: picture.width, height: picture.height)
                                .offset(x: picture.minX, y: picture.minY)
                            box(in: picture)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("Reset Box") { area = Self.defaultArea }
                    Spacer()
                    Toggle("Quick number reading", isOn: $quickReading)
                        .help("Stops reading a player's number up close once it's clearly read in the rally. Faster; compare in Check Accuracy before relying on it.")
                    Spacer()
                    Button("Skip (Automatic)") { onDone(nil) }
                }
                .font(.callout)
            }
            .padding()
            .navigationTitle("Mark Your Court")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 820, minHeight: 600)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Find Rallies") { onDone(area) }
                        .disabled(frame == nil)
                }
            }
            .task { frame = await Self.sampleFrame(url) }
        }
    }

    /// The box, the dimmed rest of the picture, and corner handles.
    private func box(in picture: CGRect) -> some View {
        let r = CGRect(x: picture.minX + area.minX * picture.width,
                       y: picture.minY + area.minY * picture.height,
                       width: area.width * picture.width,
                       height: area.height * picture.height)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the box.
            Path { p in
                p.addRect(picture)
                p.addRect(r)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.yellow, lineWidth: 2)
                .background(Color.yellow.opacity(0.08))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(.move, picture: picture))

            handle(at: CGPoint(x: r.minX, y: r.minY), .topLeft, picture: picture)
            handle(at: CGPoint(x: r.maxX, y: r.minY), .topRight, picture: picture)
            handle(at: CGPoint(x: r.minX, y: r.maxY), .bottomLeft, picture: picture)
            handle(at: CGPoint(x: r.maxX, y: r.maxY), .bottomRight, picture: picture)
        }
    }

    private func handle(at point: CGPoint, _ which: Handle, picture: CGRect) -> some View {
        Circle()
            .fill(.yellow)
            .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44) // a comfortable touch target
            .contentShape(Rectangle())
            .position(point)
            .gesture(drag(which, picture: picture))
    }

    private func drag(_ which: Handle, picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard picture.width > 0, picture.height > 0 else { return }
                let start = dragStart ?? area
                if dragStart == nil { dragStart = area }
                let dx = value.translation.width / picture.width
                let dy = value.translation.height / picture.height
                var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
                switch which {
                case .move:
                    let w = start.width, h = start.height
                    minX = min(max(0, start.minX + dx), 1 - w)
                    minY = min(max(0, start.minY + dy), 1 - h)
                    maxX = minX + w
                    maxY = minY + h
                case .topLeft:
                    minX = min(max(0, start.minX + dx), maxX - Self.minSide)
                    minY = min(max(0, start.minY + dy), maxY - Self.minSide)
                case .topRight:
                    maxX = max(min(1, start.maxX + dx), minX + Self.minSide)
                    minY = min(max(0, start.minY + dy), maxY - Self.minSide)
                case .bottomLeft:
                    minX = min(max(0, start.minX + dx), maxX - Self.minSide)
                    maxY = max(min(1, start.maxY + dy), minY + Self.minSide)
                case .bottomRight:
                    maxX = max(min(1, start.maxX + dx), minX + Self.minSide)
                    maxY = max(min(1, start.maxY + dy), minY + Self.minSide)
                }
                area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else { return .zero }
        let aspect = CGFloat(frame.width) / CGFloat(frame.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// A frame a little way into the match (the very start is often setup or a blank screen).
    private static func sampleFrame(_ url: URL) async -> CGImage? {
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        let at = duration.isFinite && duration > 0 ? min(duration * 0.1, 120) : 0
        return await VideoFrames.firstFrame(url: url, at: at, crop: nil)
    }
}

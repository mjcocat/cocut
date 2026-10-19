import AppKit
import AVKit
import SwiftUI

/// The Reel Preview window: plays the reel as it will export, with a list of its pieces.
struct ReelPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var preview: ReelPreview { model.preview }
    private var plan: [ReelEntry] { model.library.reelPlan }
    private var hasClips: Bool { !model.library.includedClips.isEmpty }

    private var currentSignature: ReelPreview.Signature {
        ReelPreview.signature(plan: plan, options: model.exporter.options,
                              profile: model.profile.profile, headshot: model.profile.headshot)
    }

    private var isStale: Bool {
        guard let built = preview.builtSignature else { return false }
        return built != currentSignature
    }

    var body: some View {
        Group {
            if !hasClips {
                ContentUnavailableView("Nothing to Preview",
                                       systemImage: "play.rectangle",
                                       description: Text("Record or import clips, and the reel plays here just as it will export."))
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        if isStale { staleBanner }
                        stage
                            .padding(16)
                        if preview.state == .ready {
                            PreviewTransport()
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    }
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                    PreviewPieceList()
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Reel Preview")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    preview.pause()
                    model.requestedSection = .export
                    openWindow(id: "main")
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Go to Export to save the finished video")
            }
        }
        .onAppear { buildIfNeeded() }
        .onDisappear { preview.close() }
        .onChange(of: model.isBusy) { _, busy in
            if busy { preview.pause() }
        }
    }

    private var subtitle: String {
        guard preview.state == .ready else { return "" }
        let clips = preview.pieces.filter { !$0.segment.isCard }.count
        return "\(clips) \(clips == 1 ? "clip" : "clips") · \(Clip.format(preview.duration))"
    }

    private func buildIfNeeded() {
        guard hasClips, preview.builtSignature != currentSignature, !preview.isBuilding else { return }
        rebuild()
    }

    private func rebuild() {
        preview.build(plan: plan, library: model.library, profile: model.profile.profile,
                      headshot: model.profile.headshot, options: model.exporter.options)
    }

    // MARK: Pieces

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.accentColor)
            Text("The reel has changed since this preview was made.")
            Spacer()
            Button("Update Preview") { rebuild() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("r", modifiers: [.command])
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.1))
    }

    @ViewBuilder
    private var stage: some View {
        ZStack {
            Color.black
            switch preview.state {
            case .ready:
                if let player = preview.player {
                    PreviewPlayerView(player: player)
                    CaptionOverlay()
                        .allowsHitTesting(false)
                }
            case .building(let message):
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(message).foregroundStyle(.white.opacity(0.85))
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("The preview couldn't be made").font(.headline).foregroundStyle(.white)
                    Text(message)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    HStack {
                        Button("Try Again") { rebuild() }
                        Button("Show Log") { Log.reveal() }
                    }
                }
                .padding()
            case .idle:
                EmptyView()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transport

/// Play/pause, previous/next clip, times and the timeline. Its own view so the frequent
/// time updates only redraw this part.
private struct PreviewTransport: View {
    @Environment(AppModel.self) private var model
    private var preview: ReelPreview { model.preview }

    var body: some View {
        transport
    }

    private var transport: some View {
        VStack(spacing: 10) {
            PreviewTimeline()
                .frame(height: 22)

            HStack(spacing: 14) {
                Text(ReelPreviewView.time(preview.currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Spacer()

                Button { preview.step(by: -1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Previous clip (⌘←)")
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button { preview.togglePlay() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 34, height: 28)
                }
                .help("Play or pause (Space)")
                .keyboardShortcut(.space, modifiers: [])

                Button { preview.step(by: 1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help("Next clip (⌘→)")
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Spacer()

                Text(ReelPreviewView.time(preview.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .font(.title3)

            if let index = preview.currentPieceIndex {
                Text(nowShowing(index))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func nowShowing(_ index: Int) -> String {
        let piece = preview.pieces[index]
        if piece.segment.isCard { return piece.segment.cardLabel ?? "Card" }
        let clips = preview.pieces.filter { !$0.segment.isCard }
        let number = (clips.firstIndex { $0.id == piece.id } ?? 0) + 1
        return "Clip \(number) of \(clips.count) · \(piece.segment.title ?? "")"
    }

}

// MARK: - Timeline strip

/// The reel as a strip of blocks, one per piece, sized by length. Click or drag to scrub.
private struct PreviewTimeline: View {
    @Environment(AppModel.self) private var model
    private var preview: ReelPreview { model.preview }

    var body: some View {
        GeometryReader { geo in
            let total = max(preview.duration, 0.01)
            let current = preview.currentPieceIndex
            ZStack(alignment: .leading) {
                ForEach(preview.pieces) { piece in
                    let x = geo.size.width * piece.start / total
                    let w = max(2, geo.size.width * piece.duration / total - 2)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(fill(for: piece, current: current == piece.id))
                        .frame(width: w, height: geo.size.height)
                        .offset(x: x)
                }
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: geo.size.width * preview.currentTime / total - 1, y: 0)
                    .shadow(radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = min(1, max(0, value.location.x / geo.size.width))
                preview.seek(to: fraction * total)
            })
        }
        .help("Click to jump anywhere in the reel")
    }

    private func fill(for piece: ReelComposer.Piece, current: Bool) -> Color {
        let accent = model.profile.profile.accentColor
        if piece.segment.isCard { return accent.opacity(current ? 0.95 : 0.55) }
        return current ? Color.accentColor : Color.primary.opacity(0.18)
    }
}

// MARK: - Piece list

private struct PreviewPieceList: View {
    @Environment(AppModel.self) private var model
    private var preview: ReelPreview { model.preview }

    var body: some View {
        let current = preview.currentPieceIndex
        VStack(alignment: .leading, spacing: 0) {
            Text("IN THIS REEL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                List {
                    ForEach(preview.pieces) { piece in
                        PreviewPieceRow(piece: piece, number: number(of: piece), isCurrent: current == piece.id)
                            .id(piece.id)
                            .contentShape(Rectangle())
                            .onTapGesture { preview.play(piece: piece) }
                            .listRowBackground(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(current == piece.id ? 0.18 : 0)))
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: current) { _, index in
                    guard let index, preview.isPlaying else { return }
                    withAnimation { proxy.scrollTo(index, anchor: .center) }
                }
            }
            if preview.state == .ready {
                Text("Previews play at 720p. The export uses the resolution and frame rate you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
    }

    private func number(of piece: ReelComposer.Piece) -> Int? {
        guard !piece.segment.isCard else { return nil }
        return preview.pieces.filter { !$0.segment.isCard && $0.id <= piece.id }.count
    }
}

private struct PreviewPieceRow: View {
    @Environment(AppModel.self) private var model
    let piece: ReelComposer.Piece
    let number: Int?
    let isCurrent: Bool
    @State private var image: CGImage?

    private var clip: Clip? { model.library.clip(withID: piece.segment.clipID) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if piece.segment.isCard {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(model.profile.profile.accentColor.gradient)
                    Image(systemName: icon)
                        .foregroundStyle(.white)
                } else {
                    Color.black
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    }
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Text("\(ReelPreviewView.time(piece.start)) · \(Clip.format(piece.duration))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isCurrent, model.preview.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative)
            }
        }
        .padding(.vertical, 2)
        .task(id: piece.segment.url) {
            guard !piece.segment.isCard else { return }
            image = await ThumbnailLoader.shared.thumbnail(for: piece.segment.url, crop: clip?.unitCrop)
        }
    }

    private var title: String {
        if piece.segment.isCard { return piece.segment.cardLabel ?? "Card" }
        let name = piece.segment.title ?? "Clip"
        return number.map { "\($0). \(name)" } ?? name
    }

    private var icon: String {
        switch piece.segment.cardLabel {
        case "Intro card": return "person.text.rectangle"
        case "End card": return "envelope"
        default: return "text.below.photo"
        }
    }
}

// MARK: - Player

/// AVPlayerView without its own controls; the window's transport drives it.
private struct PreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// The clip-name lower third, drawn to match the exported caption.
private struct CaptionOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.height / 1080
            if let caption = model.preview.currentCaption {
                HStack(spacing: 0) {
                    model.profile.profile.accentColor.frame(width: 8 * s)
                    Text(caption.title)
                        .font(.system(size: 40 * s, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 28 * s)
                }
                .frame(height: 76 * s)
                .background(Color.black.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 14 * s, style: .continuous))
                .opacity(caption.opacity)
                .frame(maxWidth: geo.size.width * 0.8, alignment: .leading)
                .padding(.leading, 60 * s)
                .padding(.bottom, 70 * s)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}

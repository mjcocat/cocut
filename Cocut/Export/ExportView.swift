import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var exporter: ReelExporter { model.exporter }
    private var clips: [Clip] { model.library.includedClips }
    private var plan: [ReelEntry] { model.library.reelPlan }
    private var profile: PlayerProfile { model.profile.profile }

    var body: some View {
        @Bindable var exporter = self.exporter
        @Bindable var store = model.profile
        Form {
            Section {
                summary
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your Reel")
                    Spacer()
                    Text(clips.isEmpty ? "No clips" : "About \(Clip.format(exporter.estimatedDuration(plan: plan, profile: profile)))")
                        .monospacedDigit()
                }
            }

            status

            if !exporter.isRunning {
                Section("Cards") {
                    Toggle("Start with the intro card", isOn: $exporter.options.includeIntro)
                    Toggle(isOn: $exporter.options.introProgressBar) {
                        Text("Progress bar on the intro card")
                        Text("A bar in the theme color fills along the bottom, so viewers can tell the video is playing.")
                    }
                    .disabled(!exporter.options.includeIntro)
                    Toggle("End with the contact card", isOn: $store.profile.showEndCard)
                    Stepper(value: $exporter.options.cardSeconds, in: 3...10, step: 1) {
                        Text("Show each card for \(Int(exporter.options.cardSeconds)) seconds")
                    }
                    .disabled(!exporter.options.includeIntro && !store.profile.showEndCard)
                }

                Section("Clips") {
                    Picker("Between clips", selection: $exporter.options.transition) {
                        ForEach(ReelTransition.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(isOn: $exporter.options.showClipNames) {
                        Text("Show clip names")
                        Text("A caption at the start of each clip. Rename clips first, like “Kill vs. Thunder”.")
                    }
                    Toggle(isOn: $exporter.options.showSpotlights) {
                        Text("Player spotlights")
                        Text("Clips with a spotlight open on a held frame with a ring around the athlete.")
                    }
                    if exporter.options.showSpotlights {
                        LabeledContent("Spotlight shape and color") {
                            SpotlightStyleControls()
                        }
                    }
                    Toggle("Include sound", isOn: $exporter.options.includeSound)
                }

                Section {
                    Picker("Resolution", selection: $exporter.options.resolution) {
                        ForEach(ReelResolution.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Frame rate", selection: $exporter.options.frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Toggle(isOn: $exporter.options.removeBlackBars) {
                        Text("Remove black bars around clips")
                        Text("Finds the picture in each clip, such as a 16:9 video recorded full screen, and enlarges it to the frame.")
                    }
                    Toggle(isOn: $exporter.options.fillFrame) {
                        Text("Fill the whole frame")
                        Text("Crops the edges of clips that aren't 16:9 instead of leaving bars.")
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("1080p at 30 fps plays everywhere and keeps files small for email and recruiting sites.")
                }

                Section {
                    HStack(spacing: Design.Space.s) {
                        Spacer()
                        Button {
                            openWindow(id: "preview")
                        } label: {
                            Label("Preview", systemImage: "play.rectangle")
                        }
                        .help("Watch the reel with these settings before exporting (⌘Y)")
                        .disabled(clips.isEmpty)
                        Button {
                            startExport()
                        } label: {
                            Label("Export Highlight Reel…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(clips.isEmpty)
                    }
                    .controlSize(.large)
                }
            }
        }
        .formStyle(.grouped)
        .motion(value: exporter.isRunning)
        .navigationTitle("Export")
        .navigationSubtitle(clips.isEmpty ? "Nothing to export yet" : "\(clips.count) clips · about \(Clip.format(exporter.estimatedDuration(plan: plan, profile: profile)))")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if exporter.isRunning {
                    Button("Cancel Export", role: .cancel) { exporter.cancel() }
                } else {
                    Button {
                        startExport()
                    } label: {
                        Label("Export Reel…", systemImage: "square.and.arrow.up")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clips.isEmpty)
                }
            }
        }
    }

    // MARK: Summary

    /// The reel in order: cards, section dividers and clips, as a strip of thumbnails.
    @ViewBuilder
    private var summary: some View {
        if clips.isEmpty {
            Text("Add clips and include them in the reel, and they'll appear here in order.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: Design.Space.s + 2) {
                    if exporter.options.includeIntro {
                        cardChip(kind: .intro, label: "Intro")
                    }
                    ForEach(Array(plan.enumerated()), id: \.offset) { _, entry in
                        switch entry {
                        case .section(let section):
                            cardChip(kind: .section(section.title), label: section.title)
                        case .clip(let clip):
                            ExportClipChip(number: (clips.firstIndex { $0.id == clip.id } ?? 0) + 1,
                                           clip: clip, url: model.library.url(for: clip))
                        }
                    }
                    if profile.showEndCard {
                        cardChip(kind: .end, label: "End")
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
            .scrollIndicators(.automatic)
        }

        if profile.isEmpty, exporter.options.includeIntro {
            HStack(spacing: Design.Space.s) {
                Image(systemName: "person.text.rectangle").foregroundStyle(Color.accentColor)
                Text("Your intro card has no name yet.")
                Spacer()
                Button("Fill In the Player Card") { model.requestedSection = .playerCard }
            }
            .font(.callout)
        }
        if model.library.clips.count != clips.count {
            let out = model.library.clips.count - clips.count
            Text("\(out) \(out == 1 ? "clip is" : "clips are") left out of the reel. Include them from the Clips list.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func cardChip(kind: CardKind, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PlayerCardView(profile: profile, headshot: model.profile.headshot, kind: kind)
                .scaleEffect(128 / PlayerCardView.canvas.width, anchor: .topLeading)
                .frame(width: 128, height: 72, alignment: .topLeading)
                .mediaFrame(radius: Design.Radius.small)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 128, alignment: .leading)
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch exporter.state {
        case .idle:
            EmptyView()
        case .preparing(let message):
            progressSection(title: message, fraction: nil)
        case .exporting(let fraction):
            progressSection(title: "Exporting… \(Int(fraction * 100))%", fraction: fraction)
        case .finished(let url):
            Section {
                FinishedCard(url: url, onDone: { exporter.reset() })
            }
        case .failed(let message):
            Section {
                HStack(alignment: .top, spacing: Design.Space.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        Text("The export didn't finish").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Show Log") { Log.reveal() }
                    Button("Try Again") { startExport() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func progressSection(title: String, fraction: Double?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Text(title).font(.headline).monospacedDigit()
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text("You can keep using your Mac while Cocut exports.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { exporter.cancel() }
                }
            }
            .padding(.vertical, Design.Space.xs)
        }
    }

    // MARK: Actions

    private func startExport() {
        guard !clips.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Highlight Reel"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = exporter.exportsDirectory
        let name = profile.fullName.isEmpty ? "Highlights" : "\(profile.fullName) Highlights"
        panel.nameFieldStringValue = "\(name).mp4"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporter.export(plan: plan, library: model.library, profile: profile,
                        headshot: model.profile.headshot, to: url)
    }
}

private struct ExportClipChip: View {
    let number: Int
    let clip: Clip
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.black
                .frame(width: 128, height: 72)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(4)
                }
                .mediaFrame(radius: Design.Radius.small)
            Text("\(clip.title) · \(clip.durationText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
        }
        .task(id: url) { image = await ThumbnailLoader.shared.thumbnail(for: url, crop: clip.unitCrop) }
    }
}

private struct FinishedCard: View {
    let url: URL
    let onDone: () -> Void
    @State private var player: AVPlayer?
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your highlight reel is ready").font(.headline)
                    Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Done", action: onDone)
            }
            if let player {
                VideoPlayerView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .mediaFrame()
            }
            HStack(spacing: Design.Space.s) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button {
                    uploading = true
                } label: {
                    Label("Upload to YouTube…", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Upload as an unlisted video, with a description from your Player Card")
            }
        }
        .padding(.vertical, Design.Space.xs)
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $uploading) { YouTubeUploadSheet(file: url) }
    }
}

/// AVPlayerView for the finished reel.
private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

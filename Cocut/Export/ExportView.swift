import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(AppModel.self) private var model

    private var exporter: ReelExporter { model.exporter }
    private var clips: [Clip] { model.library.includedClips }
    private var profile: PlayerProfile { model.profile.profile }

    var body: some View {
        @Bindable var exporter = self.exporter
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summary
                status
                if !exporter.isRunning {
                    optionsForm(exporter: exporter)
                }
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Export")
        .navigationSubtitle(clips.isEmpty ? "Nothing to export yet" : "\(clips.count) clips · about \(Clip.format(exporter.estimatedDuration(clips: clips, profile: profile)))")
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your reel").font(.title2.weight(.semibold))
                Spacer()
                Text(clips.isEmpty ? "No clips" : "About \(Clip.format(exporter.estimatedDuration(clips: clips, profile: profile)))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    if exporter.options.includeIntro {
                        cardChip(kind: .intro, label: "Intro")
                    }
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        ExportClipChip(number: index + 1, clip: clip, url: model.library.url(for: clip))
                    }
                    if profile.showEndCard {
                        cardChip(kind: .end, label: "End")
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)

            if profile.isEmpty, exporter.options.includeIntro {
                Label {
                    Text("Your intro card has no name yet. ") + Text("Fill in the Player Card").bold() + Text(" to personalize it.")
                } icon: {
                    Image(systemName: "person.text.rectangle").foregroundStyle(Color.accentColor)
                }
                .font(.callout)
                .onTapGesture { model.requestedSection = .playerCard }
            }
            if model.library.clips.count != clips.count {
                Text("\(model.library.clips.count - clips.count) clip(s) are left out of the reel. Include them from the Clips list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func cardChip(kind: CardKind, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PlayerCardView(profile: profile, headshot: model.profile.headshot, kind: kind)
                .scaleEffect(128 / PlayerCardView.canvas.width, anchor: .topLeading)
                .frame(width: 128, height: 72, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch exporter.state {
        case .idle:
            EmptyView()
        case .preparing(let message):
            progressCard(title: message, fraction: nil)
        case .exporting(let fraction):
            progressCard(title: "Exporting… \(Int(fraction * 100))%", fraction: fraction)
        case .finished(let url):
            FinishedCard(url: url, onDone: { exporter.reset() })
        case .failed(let message):
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The export didn't finish").font(.headline)
                    Text(message).foregroundStyle(.secondary)
                    HStack {
                        Button("Try Again") { startExport() }
                        Button("Show Log") { Log.reveal() }.buttonStyle(.borderless)
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.1)))
        }
    }

    private func progressCard(title: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }

    // MARK: Options

    private func optionsForm(exporter: ReelExporter) -> some View {
        @Bindable var exporter = exporter
        @Bindable var store = model.profile
        return VStack(alignment: .leading, spacing: 18) {
            group("Cards") {
                Toggle("Start with the intro card", isOn: $exporter.options.includeIntro)
                Toggle("End with the contact card", isOn: $store.profile.showEndCard)
                Stepper(value: $exporter.options.cardSeconds, in: 3...10, step: 1) {
                    Text("Show each card for \(Int(exporter.options.cardSeconds)) seconds")
                }
                .disabled(!exporter.options.includeIntro && !store.profile.showEndCard)
            }
            group("Clips") {
                Picker("Between clips", selection: $exporter.options.transition) {
                    ForEach(ReelTransition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Toggle(isOn: $exporter.options.showClipNames) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show clip names")
                        Text("A caption at the start of each clip. Rename clips first, like “Kill vs. Thunder”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Include sound", isOn: $exporter.options.includeSound)
            }
            group("Video") {
                Picker("Resolution", selection: $exporter.options.resolution) {
                    ForEach(ReelResolution.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Picker("Frame rate", selection: $exporter.options.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text("1080p at 30 fps plays everywhere and keeps files small for email and recruiting sites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    startExport()
                } label: {
                    Label("Export Highlight Reel…", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(clips.isEmpty)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04)))
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
        exporter.export(clips: clips, library: model.library, profile: profile,
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
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("\(clip.title) · \(clip.durationText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
        }
        .task(id: url) { image = await ThumbnailLoader.shared.thumbnail(for: url) }
    }
}

private struct FinishedCard: View {
    let url: URL
    let onDone: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your highlight reel is ready").font(.headline)
                    Text(url.lastPathComponent).foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done", action: onDone)
            }
            if let player {
                VideoPlayerView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.green.opacity(0.08)))
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
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

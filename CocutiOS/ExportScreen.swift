import AVKit
import SwiftUI

/// Preview the reel, choose the export settings, export an MP4, then share or save it.
struct ExportScreen: View {
    @Environment(IOSModel.self) private var model
    @State private var previewing = false
    @State private var finished: URL?

    var body: some View {
        @Bindable var exporter = model.exporter
        let library = model.library
        let profile = model.profile.profile
        let plan = library.reelPlan
        let clipCount = plan.filter { if case .clip = $0 { return true } else { return false } }.count

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Clips in the reel", value: "\(clipCount)")
                    LabeledContent("Length", value: Clip.format(exporter.estimatedDuration(plan: plan, profile: profile)))
                    Button("Preview Reel", systemImage: "play.rectangle") { previewing = true }
                        .disabled(clipCount == 0)
                }

                Section("Video") {
                    Picker("Resolution", selection: $exporter.options.resolution) {
                        ForEach(ReelResolution.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Frame rate", selection: $exporter.options.frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("Between clips", selection: $exporter.options.transition) {
                        ForEach(ReelTransition.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Sound", isOn: $exporter.options.includeSound)
                    Toggle("Clip names as captions", isOn: $exporter.options.showClipNames)
                    Toggle("Fill the frame (crop edges)", isOn: $exporter.options.fillFrame)
                    Toggle("“Made with Cocut” mark", isOn: $exporter.options.madeWithCocut)
                }

                Section("Cards") {
                    Toggle("Intro card", isOn: $exporter.options.includeIntro)
                    if exporter.options.includeIntro {
                        Toggle("Progress bar on the intro card", isOn: $exporter.options.introProgressBar)
                    }
                    Stepper("Show cards for \(Int(exporter.options.cardSeconds)) s",
                            value: $exporter.options.cardSeconds, in: 2...10, step: 1)
                }

                Section("Spotlights") {
                    Toggle("Player spotlights", isOn: $exporter.options.showSpotlights)
                    if exporter.options.showSpotlights {
                        Picker("Shape", selection: $exporter.options.spotlightShape) {
                            ForEach(SpotlightShape.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Ring", selection: $exporter.options.spotlightRing) {
                            ForEach(SpotlightRing.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }

                Section {
                    switch exporter.state {
                    case .preparing(let message):
                        progressRow(message, fraction: nil)
                    case .exporting(let fraction):
                        progressRow("Exporting… \(Int(fraction * 100))%", fraction: fraction)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        exportButton(plan: plan, disabled: clipCount == 0)
                    case .finished(let url):
                        Button("Open Last Export", systemImage: "film") { finished = url }
                        exportButton(plan: plan, disabled: clipCount == 0)
                    case .idle:
                        exportButton(plan: plan, disabled: clipCount == 0)
                    }
                } footer: {
                    Text("Keep Cocut open while it exports. Finished reels are also kept in Cocut's folder in the Files app.")
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProjectMenu() }
            }
            .onChange(of: exporter.state) { _, state in
                if case .finished(let url) = state { finished = url }
                UIApplication.shared.isIdleTimerDisabled = exporter.isRunning
            }
            .sheet(item: $finished) { url in
                FinishedVideoSheet(url: url, title: "Highlight Reel")
            }
            .fullScreenCover(isPresented: $previewing) {
                ReelPreviewScreen()
            }
        }
    }

    private func progressRow(_ message: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
            if let fraction { ProgressView(value: fraction) } else { ProgressView() }
            Button("Cancel", role: .cancel) { model.exporter.cancel() }
        }
    }

    private func exportButton(plan: [ReelEntry], disabled: Bool) -> some View {
        Button {
            let profile = model.profile.profile
            let name = profile.fullName.isEmpty ? "Highlights" : "\(profile.fullName) Highlights"
            var output = model.exporter.exportsDirectory.appending(path: "\(name).mp4")
            var n = 2
            while FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) {
                output = model.exporter.exportsDirectory.appending(path: "\(name) \(n).mp4")
                n += 1
            }
            model.exporter.export(plan: plan, library: model.library, profile: profile,
                                  headshot: model.profile.headshot, to: output)
        } label: {
            Label("Export Highlight Reel", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
    }
}

/// Plays the reel as it will export, without rendering a file.
struct ReelPreviewScreen: View {
    @Environment(IOSModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preview = model.preview
        NavigationStack {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    VideoPlayer(player: preview.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                    if let caption = preview.currentCaption {
                        Text(caption.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                            .padding(12)
                            .opacity(caption.opacity)
                            .allowsHitTesting(false)
                    }
                    if case .building(let message) = preview.state {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(message).font(.callout)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.6))
                    }
                    if case .failed(let message) = preview.state {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.6))
                    }
                }
                HStack(spacing: 24) {
                    Button { preview.step(by: -1) } label: { Image(systemName: "backward.end.fill") }
                    Button { preview.togglePlay() } label: {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill").font(.title)
                    }
                    Button { preview.step(by: 1) } label: { Image(systemName: "forward.end.fill") }
                }
                .disabled(preview.state != .ready)
                Text("\(Clip.format(preview.currentTime)) / \(Clip.format(preview.duration)) · previews play at 720p")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Preview Reel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        preview.close()
                        dismiss()
                    }
                }
            }
            .task {
                preview.build(plan: model.library.reelPlan, library: model.library, profile: model.profile.profile,
                              headshot: model.profile.headshot, options: model.exporter.options)
            }
        }
    }
}

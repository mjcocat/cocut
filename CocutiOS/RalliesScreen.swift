import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Find Rallies: pick a full match, let Cocut find the rallies, review them, then add them to
/// Clips or export the match without the dead time.
struct RalliesScreen: View {
    @Environment(IOSModel.self) private var model
    var onAddedToClips: () -> Void = {}

    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var loadingMatch = false
    @State private var sharing: URL?
    @State private var loadProblem: String?
    /// A match waiting for its court area to be marked before analysis.
    @State private var pendingMatch: URL?
    @State private var teaching = false
    @State private var editingRoster = false
    @State private var checkingAccuracy = false

    var body: some View {
        let finder = model.rallies
        NavigationStack {
            Group {
                switch finder.state {
                case .empty:
                    emptyView
                case .analyzing(let fraction):
                    analyzingView(fraction)
                case .review:
                    RallyReview()
                case .working(let message, let fraction):
                    VStack(spacing: 14) {
                        if let fraction {
                            ProgressView(value: fraction).frame(maxWidth: 320)
                        } else {
                            ProgressView()
                        }
                        Text(message).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { finder.cancelWork() }
                    }
                    .padding()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Something Went Wrong", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("OK") { finder.dismissError() }
                    }
                }
            }
            .navigationTitle(finder.sourceURL == nil ? "Find Rallies" : finder.matchName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProjectMenu() }
                if finder.state == .review {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { finder.undo() }
                            .disabled(!finder.canUndo)
                        Menu {
                            Button("Add to Clips", systemImage: "film.stack") {
                                finder.addToClips(library: model.library)
                            }
                            .disabled(finder.keptRallies.isEmpty)
                            Button("Export Condensed Match…", systemImage: "square.and.arrow.up") {
                                let output = FileManager.default.temporaryDirectory.appending(path: finder.condensedFileName)
                                finder.lastCondensedURL = nil
                                finder.exportCondensed(to: output)
                            }
                            .disabled(finder.keptRallies.isEmpty)
                            Divider()
                            Button("Team Roster…", systemImage: "person.3") { editingRoster = true }
                            Button("Identify Players…", systemImage: "person.badge.plus") {
                                finder.pause()
                                teaching = true
                            }
                            .disabled(!finder.canTeach)
                            Button("Check Accuracy…", systemImage: "checkmark.seal") {
                                finder.pause()
                                checkingAccuracy = true
                            }
                            .disabled(!finder.canTeach)
                            Button("Change Court Area…", systemImage: "rectangle.dashed") {
                                pendingMatch = finder.sourceURL
                            }
                            Button("Choose Another Match…", systemImage: "arrow.triangle.2.circlepath") {
                                finder.reset()
                            }
                            ShareLink(item: Log.fileURL) {
                                Label("Share Log", systemImage: "doc.text")
                            }
                        } label: {
                            Label("Done", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .videos,
                          preferredItemEncoding: .current)
            .onChange(of: photoItem) { _, item in
                Log.info("Photos selection changed: \(item == nil ? "none" : "1 item")")
                guard let item else { return }
                photoItem = nil
                Task { await loadFromPhotos(item) }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result {
                    do {
                        pendingMatch = try MatchFiles.keep(url, move: false)
                    } catch {
                        Log.error("Couldn't copy the match: \(error.localizedDescription)")
                    }
                }
            }
            .onChange(of: finder.lastAddedCount) { _, count in
                if let count, count > 0 {
                    finder.lastAddedCount = nil
                    model.showNotice(count == 1 ? "Added 1 rally to Clips" : "Added \(count) rallies to Clips")
                    onAddedToClips()
                }
            }
            .onChange(of: finder.lastCondensedURL) { _, url in
                if let url { sharing = url }
            }
            .alert("Find Rallies", isPresented: Binding(get: { loadProblem != nil },
                                                        set: { if !$0 { loadProblem = nil } })) {
                Button("OK") { loadProblem = nil }
            } message: {
                Text(loadProblem ?? "")
            }
            .sheet(isPresented: $editingRoster) { RosterScreen() }
            .onChange(of: model.library.roster) { _, _ in finder.refreshPlayers() }
            .fullScreenCover(isPresented: $teaching) {
                if let url = finder.sourceURL {
                    TeachPlayerScreen(finder: finder, url: url, time: finder.currentTime) { teaching = false }
                }
            }
            .fullScreenCover(isPresented: $checkingAccuracy) {
                CheckAccuracyScreen(finder: finder) { checkingAccuracy = false }
            }
            .fullScreenCover(item: $pendingMatch) { url in
                CourtAreaScreen(url: url) { area in
                    pendingMatch = nil
                    finder.courtArea = area
                    finder.analyze(url)
                } onCancel: {
                    pendingMatch = nil
                }
            }
            .sheet(item: $sharing) { url in
                FinishedVideoSheet(url: url, title: "Condensed Match")
            }
            .onChange(of: isAnalyzing) { _, analyzing in
                // Analysis needs the app in front: keep the screen on while it runs.
                UIApplication.shared.isIdleTimerDisabled = analyzing
            }
        }
    }

    private var isAnalyzing: Bool {
        if case .analyzing = model.rallies.state { return true }
        if case .working = model.rallies.state { return true }
        return loadingMatch
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("Find the Rallies in a Match", systemImage: "volleyball")
        } description: {
            Text("Pick a full match filmed from a fixed camera, ideally a tripod behind the end line with some wall or ceiling visible above the net. Cocut cuts out the dead time and reads jersey numbers.")
        } actions: {
            if loadingMatch {
                ProgressView("Copying the match…")
            } else {
                Button("Choose from Photos") { showingPhotos = true }
                    .buttonStyle(.borderedProminent)
                Button("Choose from Files") { showingFiles = true }
                Button("Team Roster…") { editingRoster = true }
                RecentMatchesList(finder: model.rallies)
                    .padding(.top, 8)
            }
        }
    }

    private func analyzingView(_ fraction: Double) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: fraction).frame(maxWidth: 320)
            Text("Finding rallies… \(Int(fraction * 100))%")
                .font(.headline)
            Text("Keep Cocut open. This takes a few minutes for an hour of video.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", role: .cancel) { model.rallies.cancel() }
        }
        .padding()
    }

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        loadingMatch = true
        defer { loadingMatch = false }
        let loaded = await PickedMovie.load([item])
        guard let temp = loaded.urls.first else {
            loadProblem = (["Couldn't get that video from Photos."] + loaded.problems).joined(separator: "\n\n")
            return
        }
        do {
            let kept = try MatchFiles.keep(temp, move: true)
            PickedMovie.cleanUp([temp])
            pendingMatch = kept
        } catch {
            Log.error("Couldn't keep the match: \(error.localizedDescription)")
        }
    }
}


/// Review: the match player, the timeline, and the rally list.
private struct RallyReview: View {
    @Environment(IOSModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let finder = model.rallies
        if sizeClass == .regular {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    player
                    RallyTimeline()
                    transport
                    if finder.selectedRally != nil { RallyEditorBar() }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                Divider()
                RallyListView().frame(width: 360)
            }
        } else {
            VStack(spacing: 0) {
                player
                RallyTimeline()
                transport
                if finder.selectedRally != nil { RallyEditorBar() }
                RallyListView()
            }
        }
    }

    private var player: some View {
        VideoPlayer(player: model.rallies.player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)
    }

    private var transport: some View {
        @Bindable var finder = model.rallies
        return HStack(spacing: 18) {
            Button { finder.step(by: -1) } label: { Image(systemName: "backward.end.fill") }
            Button { finder.togglePlay() } label: {
                Image(systemName: finder.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button { finder.step(by: 1) } label: { Image(systemName: "forward.end.fill") }
            Text("\(Clip.format(finder.currentTime)) / \(Clip.format(finder.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Rallies only", isOn: $finder.watchCondensed)
                .toggleStyle(.button)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// The whole match, with each rally as a block. Tap or drag to seek.
private struct RallyTimeline: View {
    @Environment(IOSModel.self) private var model

    var body: some View {
        let finder = model.rallies
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(finder.duration, 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                ForEach(finder.rallies) { rally in
                    Rectangle()
                        .fill(rally.isIncluded ? Color.accentColor : Color.gray.opacity(0.5))
                        .opacity(rally.id == finder.selectedID ? 1 : 0.75)
                        .frame(width: max(2, w * rally.duration / total))
                        .offset(x: w * rally.start / total)
                }
                Rectangle().fill(.white)
                    .frame(width: 2)
                    .offset(x: w * finder.currentTime / total - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                finder.seek(to: max(0, min(1, value.location.x / w)) * total)
            })
        }
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// Adjust the selected rally.
private struct RallyEditorBar: View {
    @Environment(IOSModel.self) private var model

    var body: some View {
        let finder = model.rallies
        if let rally = finder.selectedRally {
            VStack(spacing: 6) {
                HStack {
                    Text("Rally \(finder.number(of: rally))").font(.subheadline.weight(.semibold))
                    Text("\(Clip.format(rally.start))–\(Clip.format(rally.end))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive) { finder.delete(rally.id) }
                        .labelStyle(.iconOnly)
                }
                HStack {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    Button("−½s") { finder.nudge(start: -0.5) }
                    Button("+½s") { finder.nudge(start: 0.5) }
                    Button("Here") { finder.setStartToPlayhead() }
                    Spacer()
                    Text("End").font(.caption).foregroundStyle(.secondary)
                    Button("−½s") { finder.nudge(end: -0.5) }
                    Button("+½s") { finder.nudge(end: 0.5) }
                    Button("Here") { finder.setEndToPlayhead() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
    }
}

private struct RallyListView: View {
    @Environment(IOSModel.self) private var model
    @State private var addingPlayer = false
    @State private var playerText = ""

    var body: some View {
        @Bindable var finder = model.rallies
        List(selection: $finder.selectedID) {
            if let number = finder.playerFilter {
                HStack {
                    Label("Only rallies with \(model.library.playerLabel(number))", systemImage: "person.fill")
                        .font(.subheadline)
                    Spacer()
                    Button("Show All") { finder.playerFilter = nil }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .listRowBackground(Color.accentColor.opacity(0.12))
            }
            Section {
                ForEach(finder.visibleRallies) { rally in
                    HStack(spacing: 10) {
                        Button {
                            finder.toggle(rally.id)
                        } label: {
                            Image(systemName: rally.isIncluded ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(rally.isIncluded ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rally \(finder.number(of: rally))\(rally.isManual ? " (added)" : "")")
                                .font(.body.weight(.medium))
                            HStack(spacing: 6) {
                                Text(Clip.format(rally.duration))
                                if !rally.players.isEmpty {
                                    Text(rally.players.map { "#\($0)" }.joined(separator: " "))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { finder.play(rally) }
                    .tag(rally.id)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { finder.delete(rally.id) }
                        Button("Add Player", systemImage: "person.badge.plus") {
                            finder.selectedID = rally.id
                            playerText = ""
                            addingPlayer = true
                        }
                    }
                }
            } header: {
                HStack {
                    Text("\(finder.keptRallies.count) kept · \(Clip.format(finder.keptSeconds))")
                    Spacer()
                    Menu("Keep") {
                        Button("Keep All") { finder.setAllIncluded(true) }
                        Button("Keep None") { finder.setAllIncluded(false) }
                    }
                    Menu {
                        Picker("Player", selection: $finder.playerFilter) {
                            Text("All Players").tag(Int?.none)
                            ForEach(finder.playerCounts, id: \.number) { entry in
                                Text("\(model.library.playerLabel(entry.number)) · \(entry.rallies) rallies").tag(Int?.some(entry.number))
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(finder.playerFilter.map { "#\($0)" } ?? "All Players",
                              systemImage: finder.playerFilter == nil
                                ? "line.3.horizontal.decrease.circle"
                                : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                .textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Include serve setup", isOn: $finder.includeServeSetup)
                    Button("Add Rally Here", systemImage: "plus") { finder.addRallyAtPlayhead() }
                }
                .padding(.top, 6)
            }
        }
        .listStyle(.plain)
        .alert("Add Player", isPresented: $addingPlayer) {
            TextField("Jersey number", text: $playerText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                if let n = Int(playerText.trimmingCharacters(in: .whitespaces)), let id = finder.selectedID {
                    finder.addPlayer(n, to: id)
                }
            }
        }
    }
}

/// Share a finished video, or save it to Photos.
struct FinishedVideoSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var status: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task {
                            do {
                                try await PhotoLibrarySaver.save(url)
                                status = "Saved to Photos"
                            } catch {
                                status = "Couldn't save: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
        }
    }
}

import AppKit
import AVKit
import SwiftUI

/// The Find Rallies window: pick a full match, let Cocut find the rallies, review, then use them.
struct RallyFinderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var finder: RallyFinder { model.rallies }
    @State private var teaching = false
    @State private var editingRoster = false

    var body: some View {
        Group {
            switch finder.state {
            case .empty:
                emptyState
            case .analyzing(let fraction):
                analyzing(fraction)
            case .failed(let message):
                failed(message)
            case .review, .working:
                review
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Find Rallies")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    finder.chooseMatch()
                } label: {
                    Label("Open Match…", systemImage: "film")
                }
                .help("Choose a full match video to find rallies in")
                .disabled(isBusy)
            }
        }
        .onChange(of: model.isBusy) { _, busy in
            if busy { finder.pause() }
        }
        .onChange(of: model.library.roster) { _, _ in finder.refreshPlayers() }
        .sheet(isPresented: $editingRoster) {
            RosterView()
                .frame(minWidth: 420, minHeight: 460)
        }
        .sheet(isPresented: $teaching) {
            if let url = finder.sourceURL {
                TeachPlayerScreen(finder: finder, url: url, time: finder.currentTime) { teaching = false }
            }
        }
        .sheet(item: Binding(get: { finder.pendingMatch }, set: { finder.pendingMatch = $0 })) { url in
            CourtAreaScreen(url: url) { area in
                finder.pendingMatch = nil
                finder.courtArea = area
                finder.analyze(url)
            } onCancel: {
                finder.pendingMatch = nil
            }
        }
    }

    private var isBusy: Bool {
        switch finder.state {
        case .analyzing, .working: return true
        default: return false
        }
    }

    private var subtitle: String {
        guard finder.analysis != nil else { return "" }
        return "\(finder.matchName) · \(finder.keptRallies.count) rallies · \(RallyFinderView.time(finder.keptSeconds)) of \(RallyFinderView.time(finder.duration))"
    }

    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func preciseTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "figure.volleyball")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Find the Rallies in a Match")
                .font(.title.weight(.semibold))
            Text("Choose a full match video. Cocut watches for the ball in the air and listens for the referee's whistle, then keeps just the rallies, so an hour of film becomes a list of plays.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button {
                finder.chooseMatch()
            } label: {
                Label("Choose Match Video…", systemImage: "film")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Team Roster…") { editingRoster = true }
                .help("Your team's jersey numbers: only these are listed on rallies, so opponents and misreads are left out")

            VStack(alignment: .leading, spacing: 8) {
                tip("camera.fill", "Works best with a camera on a tripod, behind the end line, that doesn't pan or zoom.")
                tip("arrow.up.and.down", "Leave some wall or ceiling above the net in the picture. That's where Cocut looks for the ball.")
                tip("rectangle.dashed", "Before it starts, you mark the air above your court, so other courts and the crowd are ignored.")
                tip("speaker.wave.2", "Keep the sound: the referee's whistle marks where rallies start and end.")
                tip("hand.tap", "You review every rally before anything is saved, and can fix or add any it got wrong.")
            }
            .font(.callout)
            .padding(18)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            finder.pendingMatch = url
            return true
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
        }
    }

    private func analyzing(_ fraction: Double) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)
            Text("Finding rallies in “\(finder.matchName)”…")
                .font(.title2.weight(.semibold))
            ProgressView(value: fraction)
                .frame(width: 360)
            Text("\(Int(fraction * 100))%  ·  Watching for the ball and listening for whistles. An hour of video takes a few minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { finder.cancel() }
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("That didn't work").font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Button("Back") { finder.dismissError() }
                Button("Choose Another Video…") { finder.chooseMatch() }
                    .buttonStyle(.borderedProminent)
                Button("Show Log") { Log.reveal() }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Review

    private var review: some View {
        VStack(spacing: 0) {
            if let count = finder.lastAddedCount {
                addedBanner(count)
            }
            HSplitView {
                VStack(spacing: 12) {
                    ZStack {
                        Color.black
                        if let player = finder.player {
                            MatchPlayerView(player: player)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    MatchTransport()
                    if let rally = finder.selectedRally {
                        RallyEditor(rally: rally)
                    }
                }
                .padding(16)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                RallyList()
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
            Divider()
            bottomBar
        }
        .overlay {
            if case .working(let message, let fraction) = finder.state {
                workingOverlay(message, fraction)
            }
        }
    }

    private func addedBanner(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Added \(count) \(count == 1 ? "rally" : "rallies") to Clips, in a section called “\(finder.matchName)”.")
            Spacer()
            Button("Show Clips") {
                model.requestedSection = .clips
                openWindow(id: "main")
            }
            Button {
                finder.lastAddedCount = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.green.opacity(0.1))
    }

    private var bottomBar: some View {
        @Bindable var finder = self.finder
        return HStack(spacing: 14) {
            Toggle(isOn: $finder.includeServeSetup) {
                Text("Include serve setup")
            }
            .help("Start each rally at the serve whistle, so you see the server get ready. Off starts just before the serve.")

            Text("\(finder.keptRallies.count) of \(finder.rallies.count) rallies · \(RallyFinderView.time(finder.keptSeconds)) kept of \(RallyFinderView.time(finder.duration))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button {
                editingRoster = true
            } label: {
                Label("Team Roster…", systemImage: "person.3")
            }
            .help("Your team's jersey numbers: only these are listed on rallies, so opponents and misreads are left out. Changes apply right away.")

            Button {
                finder.pause()
                teaching = true
            } label: {
                Label("Teach a Player…", systemImage: "person.badge.plus")
            }
            .help("Click a player and type their number; Cocut finds them in every rally by how they look")
            .disabled(isBusy || !finder.canTeach)

            Button {
                finder.pendingMatch = finder.sourceURL
            } label: {
                Label("Court Area…", systemImage: "rectangle.dashed")
            }
            .help("Mark the air above your court again and find the rallies again (replaces your changes to the rallies)")
            .disabled(isBusy)

            Button {
                finder.exportCondensed()
            } label: {
                Label("Export Condensed Match…", systemImage: "square.and.arrow.up")
            }
            .help("Save the kept rallies back to back as one video")
            .disabled(finder.keptRallies.isEmpty || isBusy)

            Button {
                finder.addToClips(library: model.library)
            } label: {
                Label(finder.playerFilter.map { "Add \(finder.keptRallies.count) with #\($0) to Clips" } ?? "Add \(finder.keptRallies.count) to Clips",
                      systemImage: "film.stack")
            }
            .buttonStyle(.borderedProminent)
            .help("Make each kept rally a clip, so you can tag the best plays and put them in your highlight reel")
            .disabled(finder.keptRallies.isEmpty || isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func workingOverlay(_ message: String, _ fraction: Double?) -> some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                Text(message).font(.headline).monospacedDigit()
                if let fraction {
                    ProgressView(value: fraction).frame(width: 300)
                } else {
                    ProgressView().progressViewStyle(.linear).frame(width: 300)
                }
                Button("Cancel") { finder.cancelWork() }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        }
    }
}

// MARK: - Transport and timeline

private struct MatchTransport: View {
    @Environment(AppModel.self) private var model
    private var finder: RallyFinder { model.rallies }

    var body: some View {
        @Bindable var finder = self.finder
        VStack(spacing: 10) {
            MatchTimeline()
                .frame(height: 26)
            HStack(spacing: 14) {
                Text(RallyFinderView.time(finder.currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)

                Toggle("Rallies only", isOn: $finder.watchCondensed)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Play the rallies back to back, skipping the dead time between them")

                Spacer()

                Button { finder.step(by: -1) } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous rally (⌘←)")
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button { finder.togglePlay() } label: {
                    Image(systemName: finder.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 34, height: 28)
                }
                .help("Play or pause (Space)")
                .keyboardShortcut(.space, modifiers: [])
                Button { finder.step(by: 1) } label: { Image(systemName: "forward.end.fill") }
                    .help("Next rally (⌘→)")
                    .keyboardShortcut(.rightArrow, modifiers: [.command])

                Spacer()

                Button {
                    finder.addRallyAtPlayhead()
                } label: {
                    Label("Add Rally Here", systemImage: "plus")
                }
                .help("Missed one? Add a rally around the playhead, then adjust its start and end")

                Text(RallyFinderView.time(finder.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// The whole match as a strip: kept rallies, left-out ones, and the playhead. Click to jump.
private struct MatchTimeline: View {
    @Environment(AppModel.self) private var model
    private var finder: RallyFinder { model.rallies }

    var body: some View {
        GeometryReader { geo in
            let total = max(finder.duration, 0.01)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                ForEach(finder.rallies) { rally in
                    let selected = rally.id == finder.selectedID
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(rally.isIncluded && finder.playerFilter.map { rally.players.contains($0) } != false
                              ? Color.accentColor.opacity(selected ? 1 : 0.7) : Color.secondary.opacity(0.3))
                        .frame(width: max(2, geo.size.width * rally.duration / total), height: geo.size.height - (selected ? 0 : 6))
                        .offset(x: geo.size.width * rally.start / total)
                }
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: geo.size.width * finder.currentTime / total - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let t = min(1, max(0, value.location.x / geo.size.width)) * total
                finder.seek(to: t)
                if let hit = finder.rallies.first(where: { t >= $0.start && t <= $0.end }) {
                    finder.selectedID = hit.id
                }
            })
        }
        .help("The whole match. Blue blocks are rallies; click anywhere to jump there.")
    }
}

// MARK: - Selected rally

private struct RallyEditor: View {
    @Environment(AppModel.self) private var model
    let rally: Rally
    private var finder: RallyFinder { model.rallies }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rally \(finder.number(of: rally))\(rally.isManual ? " (added)" : "")")
                    .font(.headline)
                Text("\(RallyFinderView.preciseTime(rally.start)) – \(RallyFinderView.preciseTime(rally.end)) · \(String(format: "%.1f", rally.duration))s")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            edgeControl("Start", minus: { finder.nudge(start: -0.5) }, plus: { finder.nudge(start: 0.5) },
                        set: { finder.setStartToPlayhead() })
            edgeControl("End", minus: { finder.nudge(end: -0.5) }, plus: { finder.nudge(end: 0.5) },
                        set: { finder.setEndToPlayhead() })
            Toggle("Keep", isOn: Binding(get: { rally.isIncluded }, set: { _ in finder.toggle(rally.id) }))
                .toggleStyle(.checkbox)
            if rally.isManual {
                Button(role: .destructive) { finder.delete(rally.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove this added rally")
            }
        }
            PlayerNumbersBar(numbers: rally.players,
                             name: { model.library.player($0)?.name.nilIfEmpty },
                             onAdd: { finder.addPlayer($0, to: rally.id) },
                             onRemove: { finder.removePlayer($0, from: rally.id) })
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func edgeControl(_ label: String, minus: @escaping () -> Void, plus: @escaping () -> Void,
                             set: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Button(action: minus) { Image(systemName: "minus") }
                    .help("\(label) half a second earlier")
                Text(label).font(.caption.weight(.semibold)).frame(width: 34)
                Button(action: plus) { Image(systemName: "plus") }
                    .help("\(label) half a second later")
            }
            .buttonStyle(.borderless)
            Button("Set to Playhead", action: set)
                .controlSize(.small)
        }
    }
}

// MARK: - List

private struct RallyList: View {
    @Environment(AppModel.self) private var model
    private var finder: RallyFinder { model.rallies }

    /// The rally under the playhead.
    private var currentID: Rally.ID? {
        let t = finder.currentTime
        return finder.rallies.first { t >= $0.start && t < $0.end }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("RALLIES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                PlayerFilterMenu()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)
            HStack(spacing: 6) {
                Text("Keep:")
                    .foregroundStyle(.secondary)
                Button("All") { finder.setAllIncluded(true) }
                    .help("Check every rally\(finder.playerFilter == nil ? "" : " in the list"), then uncheck the ones you don't want")
                Text("·").foregroundStyle(.tertiary)
                Button("None") { finder.setAllIncluded(false) }
                    .help("Uncheck every rally\(finder.playerFilter == nil ? "" : " in the list"), then check just the ones you want")
                Spacer()
                let kept = finder.visibleRallies.filter(\.isIncluded).count
                Text("\(kept) of \(finder.visibleRallies.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            ScrollViewReader { proxy in
                List(selection: Binding(get: { finder.selectedID }, set: { id in
                    finder.selectedID = id
                    if let rally = finder.rallies.first(where: { $0.id == id }) { finder.seek(to: rally.start) }
                })) {
                    ForEach(finder.visibleRallies) { rally in
                        let current = rally.id == currentID
                        RallyRow(rally: rally, number: finder.number(of: rally),
                                 isCurrent: current, isPlaying: current && finder.isPlaying)
                            .tag(rally.id)
                            .id(rally.id)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor.opacity(current ? 0.22 : 0))
                                    .padding(.horizontal, 6)
                            )
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: Rally.ID.self) { ids in
                    if let id = ids.first, let rally = finder.rallies.first(where: { $0.id == id }) {
                        Button("Play") { finder.play(rally) }
                        Button(rally.isIncluded ? "Leave Out" : "Keep") { finder.toggle(rally.id) }
                        if rally.isManual {
                            Divider()
                            Button("Remove", role: .destructive) { finder.delete(rally.id) }
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let rally = finder.rallies.first(where: { $0.id == id }) {
                        finder.play(rally)
                    }
                }
                .onChange(of: finder.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                // Follow playback from rally to rally.
                .onChange(of: currentID) { _, id in
                    guard let id, finder.isPlaying else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Text("Checked rallies are kept. Use All or None, then click checkboxes. Double-click a rally to play it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
        }
    }
}

private struct RallyRow: View {
    @Environment(AppModel.self) private var model
    let rally: Rally
    let number: Int
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 26)
                .opacity(isCurrent ? 1 : 0)
            Toggle("", isOn: Binding(get: { rally.isIncluded }, set: { _ in model.rallies.toggle(rally.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Rally \(number)")
                        .fontWeight(isCurrent ? .bold : .medium)
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    if rally.isManual {
                        Text("added").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(RallyFinderView.time(rally.start)) · \(String(format: "%.0f", rally.duration))s\(rally.players.isEmpty ? "" : "  ·  " + rally.players.map { "#\($0)" }.joined(separator: " "))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            }
        }
        .opacity(rally.isIncluded ? 1 : 0.5)
    }
}

private struct MatchPlayerView: NSViewRepresentable {
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

/// "Player" filter for the rally list: only rallies with a given jersey number.
private struct PlayerFilterMenu: View {
    @Environment(AppModel.self) private var model
    private var finder: RallyFinder { model.rallies }

    var body: some View {
        Menu {
            Button {
                finder.playerFilter = nil
            } label: {
                if finder.playerFilter == nil { Label("All Rallies", systemImage: "checkmark") } else { Text("All Rallies") }
            }
            if !finder.playerCounts.isEmpty { Divider() }
            ForEach(finder.playerCounts, id: \.number) { entry in
                let name = model.library.player(entry.number)?.name ?? ""
                let title = "#\(entry.number)\(name.isEmpty ? "" : " " + name)  (\(entry.rallies))"
                Button {
                    finder.playerFilter = finder.playerFilter == entry.number ? nil : entry.number
                } label: {
                    if finder.playerFilter == entry.number { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Label(finder.playerFilter.map { "#\($0)" } ?? "All Players",
                  systemImage: finder.playerFilter == nil ? "person.2" : "person.2.fill")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show only rallies with a player. Numbers are read from jerseys; add or remove them on a rally if one was missed.")
        .disabled(finder.playerCounts.isEmpty)
    }
}

import AppKit
import SwiftUI

/// Cocut Lab: mark where the player really is in real clips, and tune how Cocut's phone reels
/// follow them. With a command (see LabCLI), runs in Terminal instead of opening a window.
@main
enum LabMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        MainActor.assumeIsolated {
            if let first = args.first, LabCLI.commands.contains(first) {
                LabCLI.run(args)
            } else {
                LabApp.main()
            }
        }
    }
}

struct LabApp: App {
    @State private var model = LabModel()

    var body: some Scene {
        Window("Cocut Lab", id: "lab") {
            LabView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// The lab's state for the window.
@MainActor
@Observable
final class LabModel {
    var store = LabStore(folder: LabStore.defaultFolder)
    /// The clip being marked (when one clip is selected).
    var selection: UUID?
    /// Clips selected in the list (one or more).
    var selected: Set<UUID> = []
    /// Clips waiting for "remove?" to be confirmed (they have marks).
    var removing: Set<UUID> = []
    /// Which checkpoint each clip is on.
    var position: [UUID: Int] = [:]
    var image: CGImage?
    var busy: String?
    var report: String?
    /// Loading at startup: how far (0...1) and what, for the splash. Nil when ready.
    var loading: (fraction: Double, message: String)? = (0, "Opening the lab…")
    /// "Player in the phone frame: …" over every marked clip, worked out in the background.
    var overall: String?
    /// Marks per clip, for the list.
    private(set) var markCounts: [UUID: Int] = [:]
    private var overallTask: Task<Void, Never>?
    /// Playing through the checkpoints, accepting the guess at each (Space).
    var playing = false
    /// The current settings' guess per clip (by frame time), worked out when a clip opens.
    private var guesses: [UUID: [Double: PlayerChain.Person]] = [:]
    /// What Find People saw, per clip (read once from the lab folder).
    private var detectionCache: [UUID: ClipDetections] = [:]
    private var imageTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    /// The last checkpoint play accepted, and when: Space pressed just after takes it back (you
    /// press it a moment after seeing the guess was wrong).
    private var lastAccepted: (clip: UUID, index: Int, at: Date)?

    var clip: LabClip? { selection.flatMap { id in store.clips.first { $0.id == id } } }
    var checkpoints: [Double] { clip.map(LabStore.checkpoints) ?? [] }
    var index: Int { selection.flatMap { position[$0] } ?? 0 }
    var time: Double? { checkpoints.indices.contains(index) ? checkpoints[index] : nil }

    func reload() {
        store = LabStore(folder: store.folder)
        guesses = [:]
        detectionCache = [:]
        countMarks()
        refreshOverall()
    }

    /// Startup: reads each clip's saved people (the slow part) off the main thread, with progress
    /// for the splash, then works out the score.
    func start() async {
        let opened = Date()
        let clips = store.clips
        let store = self.store
        for (n, clip) in clips.enumerated() {
            loading = (Double(n) / Double(max(1, clips.count)), "Loading \(clip.title) (\(n + 1) of \(clips.count))…")
            let found = await Task.detached(priority: .userInitiated) { store.detections(clip.id) }.value
            if let found { detectionCache[clip.id] = found }
        }
        countMarks()
        loading = (1, "Scoring the current settings…")
        await computeOverall()
        // Like Cocut's splash: the logo stays up at least a moment, then fades.
        loading = (1, "Ready")
        let shown = Date().timeIntervalSince(opened)
        if shown < 1.5 { try? await Task.sleep(for: .seconds(1.5 - shown)) }
        withAnimation(.easeIn(duration: 0.35)) { loading = nil }
        findPeople()
    }

    private func countMarks() {
        markCounts = Dictionary(uniqueKeysWithValues: store.clips.map { ($0.id, store.marks($0.id).count) })
    }

    /// Recomputes the score line in the background (after a moment, so marking stays quick).
    func refreshOverall() {
        overallTask?.cancel()
        overallTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await computeOverall()
        }
    }

    private func computeOverall() async {
        let cache = detectionCache
        let store = self.store
        let text = await Task.detached(priority: .utility) { () -> String? in
            let cases = LabTuner.cases(store) { cache[$0] }
            guard !cases.isEmpty else { return nil }
            let scores = cases.map { LabTuner.score($0, settings: PlayerChain.Settings()) }
            let f = scores.map(\.framed).reduce(0, +), c = scores.map(\.checked).reduce(0, +)
            return String(format: "Player in the phone frame: %d of %d marks (%.0f%%)", f, c, 100 * Double(f) / Double(max(1, c)))
        }.value
        if !Task.isCancelled { overall = text }
    }

    /// A mark changed on `clip`: the list's count and the score.
    private func marksChanged(_ id: UUID) {
        markCounts[id] = store.marks(id).count
        refreshOverall()
    }

    func detections(_ id: UUID) -> ClipDetections? {
        if let d = detectionCache[id] { return d }
        let d = store.detections(id)
        if let d { detectionCache[id] = d }
        return d
    }

    /// Works out the current settings' guess for `clip` (after its people are found, or when a
    /// first head mark points the player out).
    func refreshGuess(_ clip: LabClip) {
        guesses[clip.id] = LabPictures.guess(store: store, clip: clip) ?? [:]
    }

    // MARK: Moving around

    func select(_ id: UUID?) {
        stopPlaying()
        selection = id
        if let id, guesses[id] == nil, let clip { refreshGuess(clip) }
        if let id, position[id] == nil {
            // Start at the first checkpoint not marked yet.
            let marked = Set(store.marks(id).map { ($0.time * 100).rounded() })
            position[id] = checkpoints.firstIndex { !marked.contains(($0 * 100).rounded()) } ?? 0
        }
        loadImage()
    }

    func move(_ delta: Int) {
        guard let id = selection, !checkpoints.isEmpty else { return }
        position[id] = min(checkpoints.count - 1, max(0, index + delta))
        loadImage()
    }

    func loadImage() {
        imageTask?.cancel()
        guard let clip, let time else { image = nil; return }
        imageTask = Task {
            let frame = await LabPictures.frame(clip: clip, at: time)
            guard !Task.isCancelled else { return }
            image = frame
        }
    }

    // MARK: Marks

    var marks: [LabMark] { selection.map { store.marks($0) } ?? [] }
    var mark: LabMark? { time.flatMap { t in marks.first { abs($0.time - t) < 0.01 } } }

    /// People found in the frame nearest the current checkpoint.
    var people: [PlayerChain.Person] {
        guard let id = selection, let time, let d = detections(id) else { return [] }
        return d.frames.min { abs($0.time - time) < abs($1.time - time) }?.people ?? []
    }

    var guess: PlayerChain.Person? {
        guard let clip, let time, let d = detections(clip.id) else { return nil }
        guard let frame = d.frames.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return nil }
        return guesses[clip.id]?[frame.time]
    }

    func setMark(_ mark: LabMark?) {
        guard let clip, let time else { return }
        store.setMark(mark, at: time, for: clip.id)
        marksChanged(clip.id)
        // A first head mark on a clip with no spotlight is what points the player out.
        if clip.spotlight == nil { refreshGuess(clip) }
        move(1)
    }

    // MARK: Playing through

    /// Steps through the checkpoints, accepting the yellow guess at each, until the end of the
    /// clip or Space. Pausing goes back to the last checkpoint it accepted and takes that back,
    /// since you press Space a moment after seeing the guess was wrong.
    func togglePlay() {
        if playing { stopPlaying(takeBack: true); return }
        guard let clip, guess != nil || mark != nil else { return }
        playing = true
        playTask = Task {
            while playing, !Task.isCancelled, selection == clip.id {
                try? await Task.sleep(for: .milliseconds(700))
                guard playing, !Task.isCancelled, selection == clip.id, let time else { break }
                if mark == nil, let g = guess {
                    store.setMark(.head(time, g.head.x, g.head.y), at: time, for: clip.id)
                    marksChanged(clip.id)
                    lastAccepted = (clip.id, index, Date())
                }
                guard index < checkpoints.count - 1 else { break }
                move(1)
            }
            playing = false
        }
    }

    func stopPlaying(takeBack: Bool = false) {
        guard playing else { return }
        playing = false
        playTask?.cancel()
        guard takeBack, let clip, let last = lastAccepted, last.clip == clip.id,
              Date().timeIntervalSince(last.at) < 0.6, checkpoints.indices.contains(last.index) else { return }
        // Accepted just before Space: take it back and go back to it.
        store.setMark(nil, at: checkpoints[last.index], for: clip.id)
        marksChanged(clip.id)
        position[clip.id] = last.index
        lastAccepted = nil
        loadImage()
    }

    func markHead(x: Double, y: Double) {
        // A click is on the moment showing, so nothing to take back.
        stopPlaying()
        guard let time else { return }
        setMark(.head(time, x, y))
    }

    func acceptGuess() {
        guard let g = guess else { return }
        markHead(x: g.head.x, y: g.head.y)
    }

    // MARK: Adding clips

    var cocutProjects: [String] { ((try? LabCLI.cocutProjects()) ?? []).map(\.project.name) }

    func importProject(_ name: String, all: Bool) {
        Task {
            _ = await LabCLI.execute(["--lab", store.folder.path(percentEncoded: false), "import-project", name] + (all ? ["--all"] : []))
            reload()
            findPeople()
        }
    }

    func addVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            _ = await LabCLI.execute(["--lab", store.folder.path(percentEncoded: false), "add"] + panel.urls.map { $0.path(percentEncoded: false) })
            reload()
            findPeople()
        }
    }

    /// The list's selection changed: one clip opens for marking; several show what's selected.
    func listSelect(_ ids: Set<UUID>) {
        selected = ids
        select(ids.count == 1 ? ids.first : nil)
    }

    /// Removes clips at once, or asks first when any have marks (those would be lost).
    func askRemove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if ids.contains(where: { !store.marks($0).isEmpty }) {
            removing = ids
        } else {
            remove(ids)
        }
    }

    func remove(_ ids: Set<UUID>) {
        for id in ids { store.remove(id) }
        store.save()
        for id in ids { detectionCache[id] = nil; markCounts[id] = nil }
        refreshOverall()
        selected.subtract(ids)
        removing = []
        if let s = selection, ids.contains(s) { select(nil) }
    }

    func marks(in ids: Set<UUID>) -> Int {
        ids.map { store.marks($0).count }.reduce(0, +)
    }

    // MARK: Finding people and tuning

    /// Finds the people in every clip that hasn't been looked at yet (runs by itself after clips
    /// are added, and when the Lab opens). The guess appears on each clip as it's done.
    func findPeople() {
        guard !findingPeople else { return }
        let todo = store.clips.filter { !store.hasDetections($0.id) }
        guard !todo.isEmpty else { return }
        findingPeople = true
        Task {
            for (n, clip) in todo.enumerated() {
                busy = "Finding people in \(clip.title) (\(n + 1) of \(todo.count))…"
                do {
                    if let found = try await PlayerTracker.detect(url: clip.videoURL, start: clip.start, end: clip.end,
                                                                  unitCrop: clip.unitCrop) {
                        store.saveDetections(found, for: clip.id)
                        detectionCache[clip.id] = found
                        refreshGuess(clip)
                        refreshOverall()
                    }
                } catch {
                    Log.error("Cocut Lab: couldn't find people in \(clip.title): \(error.localizedDescription)")
                }
            }
            busy = nil
            findingPeople = false
            // Clips added meanwhile.
            if store.clips.contains(where: { !store.hasDetections($0.id) }) { findPeople() }
        }
    }
    private var findingPeople = false

    func tune() {
        let cases = LabTuner.cases(store)
        guard cases.count >= 2 else {
            report = "Tuning needs at least 2 clips with people found and at least 3 marks each."
            return
        }
        busy = "Tuning on \(cases.count) clips…"
        let folder = store.folder
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                let r = LabTuner.tune(cases, baseline: PlayerChain.Settings(), tries: 600, seed: 1) { _ in }
                let stamp = ISO8601DateFormatter().string(from: r.date).replacingOccurrences(of: ":", with: "-")
                let md = LabTuner.markdown(r)
                let reports = folder.appending(path: "reports", directoryHint: .isDirectory)
                try? md.write(to: reports.appending(path: "tune-\(stamp).md"), atomically: true, encoding: .utf8)
                try? JSONEncoder.pretty.encode(r).write(to: reports.appending(path: "tune-\(stamp).json"))
                try? JSONEncoder.pretty.encode(r.tuned).write(to: reports.appending(path: "latest-settings.json"))
                return md
            }.value
            busy = nil
            report = text
        }
    }

    /// Player in the phone frame with the current settings, over every marked clip.
}

// MARK: - Window

struct LabView: View {
    @Environment(LabModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ClipList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if model.clip != nil {
                LabelPane()
            } else if model.selected.count > 1 {
                ContentUnavailableView {
                    Label("\(model.selected.count) Clips Selected", systemImage: "rectangle.stack")
                } description: {
                    Text("Select one clip to mark it.")
                } actions: {
                    Button("Remove from Lab", role: .destructive) { model.askRemove(model.selected) }
                }
            } else if model.store.clips.isEmpty {
                VStack(spacing: 18) {
                    Image("Logo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    Text("Add clips from a Cocut project (the ones with a spotlight) or video files, then Find People and mark where your player is every half second.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(model.store.clips.isEmpty ? "No Clips Yet" : "Choose a Clip", systemImage: "figure.volleyball")
                } description: {
                    Text(model.store.clips.isEmpty
                         ? "Add clips from a Cocut project (the ones with a spotlight) or video files, then Find People and mark where your player is every half second."
                         : "Mark where your player is: click their head, or press Return when the yellow guess is right.")
                }
            }
        }
        .toolbar { LabToolbar() }
        .task { await model.start() }
        .overlay {
            if let loading = model.loading { LabSplash(fraction: loading.fraction, message: loading.message) }
        }
        .confirmationDialog(
            model.removing.count == 1 ? "Remove this clip from the lab?" : "Remove \(model.removing.count) clips from the lab?",
            isPresented: Binding(get: { !model.removing.isEmpty }, set: { if !$0 { model.removing = [] } })
        ) {
            Button("Remove", role: .destructive) { model.remove(model.removing) }
        } message: {
            Text("Their \(model.marks(in: model.removing)) marks are removed too. The videos (and Cocut) aren't touched.")
        }
        .sheet(isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } })) {
            ReportSheet(text: model.report ?? "")
        }
    }
}

struct LabToolbar: ToolbarContent {
    @Environment(LabModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            }
            Menu {
                Section("From a Cocut Project") {
                    ForEach(model.cocutProjects, id: \.self) { name in
                        Menu(name) {
                            Button("Clips with a Spotlight") { model.importProject(name, all: false) }
                            Button("All Clips") { model.importProject(name, all: true) }
                        }
                    }
                }
                Button("Video Files…") { model.addVideos() }
            } label: {
                Label("Add Clips", systemImage: "plus")
            }
            Button {
                model.findPeople()
            } label: {
                Label("Find People", systemImage: "person.3.sequence")
            }
            .help("Find the people in clips that haven't been looked at yet (Apple's Vision, as in Cocut)")
            .disabled(model.busy != nil)
            Button {
                model.tune()
            } label: {
                Label("Tune", systemImage: "slider.horizontal.3")
            }
            .help("Search for better settings, checked on clips held out from the search")
            .disabled(model.busy != nil)
            Button {
                model.report = (try? LabCLI.rallyReport(store: model.store)) ?? "Couldn't read Cocut's projects."
            } label: {
                Label("Check Rallies", systemImage: "chart.bar.xaxis")
            }
            .help("How well Find Rallies finds rallies, scored against the rallies you settled on in your matches")
            Button {
                model.askRemove(model.selected)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .help("Remove the selected clips from the lab (Delete)")
            .disabled(model.selected.isEmpty)
            Button {
                NSWorkspace.shared.open(model.store.folder)
            } label: {
                Label("Lab Folder", systemImage: "folder")
            }
        }
    }
}

struct ClipList: View {
    @Environment(LabModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.selected }, set: { model.listSelect($0) })) {
            ForEach(model.store.clips) { clip in
                let marked = model.markCounts[clip.id] ?? 0
                let total = LabStore.checkpoints(clip).count
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title).lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: model.store.hasDetections(clip.id) ? "person.3.fill" : "person.3")
                            .foregroundStyle(model.store.hasDetections(clip.id) ? Color.green : Color.secondary)
                            .help(model.store.hasDetections(clip.id) ? "People found" : "People not found yet")
                        Text("\(marked)/\(total) marked")
                        Text(clip.group).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(clip.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Remove from Lab" : "Remove \(ids.count) Clips from Lab", role: .destructive) {
                    model.askRemove(ids)
                }
            }
        }
        // Delete (or ⌘⌫) removes the selected clips.
        .onDeleteCommand { model.askRemove(model.selected) }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let overall = model.overall { Text(overall) }
                HStack {
                    Text("Following #")
                    TextField("11", value: Binding(get: { model.store.index.number },
                                                   set: { model.store.index.number = $0; model.store.save() }),
                              format: .number)
                        .frame(width: 44)
                }
            }
            .font(.callout)
            .padding(10)
        }
    }
}

struct LabelPane: View {
    @Environment(LabModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            picture
            controls
        }
        .padding(14)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.return) { model.acceptGuess(); return .handled }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { model.move(-1); return .handled }
        .onKeyPress(.rightArrow) { model.move(1); return .handled }
        .onKeyPress(.delete) { model.setMark(nil); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "hHuU")) { press in
            model.setMark(LabMark(time: model.time ?? 0, kind: press.characters.lowercased() == "h" ? .hidden : .unsure))
            return .handled
        }
    }

    private var header: some View {
        HStack {
            if let clip = model.clip, let time = model.time {
                Text(clip.title).font(.headline)
                Text(String(format: "%.1fs", time - clip.start)).monospacedDigit()
                Text("· \(model.index + 1) of \(model.checkpoints.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                if clip.spotlight == nil, !model.marks.contains(where: { $0.kind == .head }) {
                    Text("No spotlight: your first click points out the player")
                        .foregroundStyle(.orange)
                }
                if !model.store.hasDetections(clip.id) {
                    Text(model.busy != nil ? "Finding people… the guess appears when it's done" : "Click Find People to see the guess")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var picture: some View {
        GeometryReader { geo in
            if let image = model.image {
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let s = min(geo.size.width / iw, geo.size.height / ih)
                let rect = CGRect(x: (geo.size.width - iw * s) / 2, y: (geo.size.height - ih * s) / 2, width: iw * s, height: ih * s)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    overlay(in: rect)
                }
                .contentShape(Rectangle())
                .onTapGesture { p in
                    guard rect.contains(p) else { return }
                    model.markHead(x: Double((p.x - rect.minX) / rect.width), y: Double(1 - (p.y - rect.minY) / rect.height))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func overlay(in rect: CGRect) -> some View {
        let people = model.people, guess = model.guess, mark = model.mark
        func box(_ p: PlayerChain.Person) -> CGRect {
            CGRect(x: rect.minX + p.x * rect.width, y: rect.minY + (1 - p.y - p.height) * rect.height,
                   width: p.width * rect.width, height: p.height * rect.height)
        }
        return Canvas { context, _ in
            for p in people {
                context.stroke(Path(box(p)), with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            if let guess {
                context.stroke(Path(roundedRect: box(guess).insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(.yellow), lineWidth: 3)
                let h = box(guess)
                context.fill(Path(ellipseIn: CGRect(x: h.midX - 4, y: h.minY - 4, width: 8, height: 8)), with: .color(.yellow))
            }
            if let mark, mark.kind == .head, let x = mark.x, let y = mark.y {
                let c = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + (1 - y) * rect.height)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.green), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
        .overlay(alignment: .topTrailing) {
            if let mark, mark.kind != .head {
                Text(mark.kind == .hidden ? "Marked: can't see them" : "Marked: not sure")
                    .padding(6)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { model.move(-1) } label: { Label("Back", systemImage: "chevron.left") }
                .help("Previous checkpoint (←)")
            Spacer()
            Button {
                model.togglePlay()
            } label: {
                Label(model.playing ? "Stop" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
            }
            .disabled(!model.playing && model.guess == nil)
            .help(model.playing
                  ? "Stop, and take back the guess it just accepted (Space). Then click their head."
                  : "Step through, accepting the yellow guess at each moment. Press Space when it's wrong (Space)")
            Text(model.playing ? "Space when it's wrong" : "Click their head")
                .foregroundStyle(.secondary)
            Button("Guess Is Right") { model.acceptGuess() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.guess == nil)
                .help("The yellow box is the player (Return)")
            Button("Can't See Them") {
                model.setMark(LabMark(time: model.time ?? 0, kind: .hidden))
            }
            .help("Hidden behind someone, or out of the picture (H)")
            Button("Not Sure") {
                model.setMark(LabMark(time: model.time ?? 0, kind: .unsure))
            }
            .help("Leave this one out (U)")
            Button("Clear") { model.setMark(nil) }
                .help("Remove this mark (Delete)")
                .disabled(model.mark == nil)
            Spacer()
            Button { model.move(1) } label: { Label("Next", systemImage: "chevron.right") }
                .help("Next checkpoint (→)")
        }
    }
}

struct ReportSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Saved in the lab folder's reports.").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }
}

/// Shown while the lab loads: the logo, how far along it is, and what it's doing.
struct LabSplash: View {
    let fraction: Double
    let message: String

    private var version: String {
        "Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
    }

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.07).ignoresSafeArea()
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                VStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(width: 280)
                        .tint(.cyan)
                    HStack {
                        Text(message).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))%").monospacedDigit()
                    }
                    .frame(width: 280)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                }
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .transition(.opacity)
    }
}

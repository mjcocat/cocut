import SwiftUI

/// Identify players. "Who's this?" asks about the followed players Cocut is least sure of (and
/// ones whose read number disagrees with how they look), most useful first; each answer teaches
/// it, so the rest sort themselves out. "Pick from a Frame" lets you click any player on any frame.
/// Either way Cocut then finds that player in every rally by how they look, which works even
/// when their number can't be read (a lone "1" in a slanted font, a number facing away).
struct TeachPlayerScreen: View {
    enum Mode: Hashable { case whoIsThis, pick }
    let finder: RallyFinder
    let url: URL
    let onClose: () -> Void

    @State private var time: Double
    @State private var frame: CGImage?
    @State private var people: [(box: CGRect, print: [Float], color: [Float])] = []
    @State private var loading = false
    @State private var selected: Int?
    @State private var numberText = ""
    /// A box being dragged by hand (view coordinates), for a player Cocut didn't box.
    @State private var drawing: CGRect?
    @State private var mode: Mode = .whoIsThis
    @State private var showingIdentified = false

    init(finder: RallyFinder, url: URL, time: Double, onClose: @escaping () -> Void) {
        self.finder = finder
        self.url = url
        self.onClose = onClose
        _time = State(initialValue: time)
    }

    var body: some View {
        @Bindable var finder = finder
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $mode) {
                    Text("Who's This?").tag(Mode.whoIsThis)
                    Text("Pick from a Frame").tag(Mode.pick)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if mode == .whoIsThis {
                    // A fixed page: the picture and close-ups resize, the answers are always in view.
                    WhoIsThisPane(finder: finder, url: url, onClose: onClose)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            pickPane
                            identifiedList
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Identify Players")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 1200, idealWidth: 1440, maxWidth: .infinity,
                   minHeight: 760, idealHeight: 900, maxHeight: .infinity)
            #endif
            .toolbar {
                if mode == .whoIsThis, !finder.taught.isEmpty || !finder.memory.examples.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("Identified (\(finder.taught.keys.count))") { showingIdentified = true }
                            .popover(isPresented: $showingIdentified) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) { identifiedList }
                                        .padding()
                                }
                                .frame(minWidth: 420, minHeight: 300)
                            }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .task(id: time) { if mode == .pick { await load() } }
            .onChange(of: mode) { _, mode in if mode == .pick, frame == nil { Task { await load() } } }
        }
    }

    private var pickPane: some View {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Click a player, type their number, and choose **Teach**. If a player has no box, drag a box around them. Cocut then finds them in every rally by how they look. Teaching the same player at a couple of different moments (facing toward and away from the camera) gives better matches.")
                        .font(.callout)

                    picture
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 10) {
                        Button { step(-5) } label: { Label("5s", systemImage: "gobackward.5") }
                        Button { step(5) } label: { Label("5s", systemImage: "goforward.5") }
                        Text(Clip.format(time)).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        TextField("Number", text: $numberText)
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onSubmit(teach)
                        Button("Teach", action: teach)
                            .buttonStyle(.borderedProminent)
                            .disabled(selected == nil || parsedNumber == nil)
                    }

                }
    }

    /// Who's been identified, with a way to undo, and how strict matching is.
    @ViewBuilder private var identifiedList: some View {
        @Bindable var finder = finder
                    if !finder.memory.examples.isEmpty {
                        HStack {
                            Text("Remembered from earlier matches: " + finder.memory.labels
                                .map { $0 == RallyDetector.otherTeam ? "other team" : "#\($0)" }.joined(separator: ", "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget All", role: .destructive) { finder.clearMemory() }
                                .buttonStyle(.borderless)
                                .help("Forget the players this project remembers (this match's answers stay)")
                        }
                    }
                    if !finder.taught.isEmpty {
                        DisclosureGroup("Identified (\(finder.taught.keys.count))") {
                        ForEach(finder.taught.keys.sorted(), id: \.self) { number in
                            HStack {
                                Text(number == RallyDetector.otherTeam ? "Other team" : "#\(number)")
                                    .font(.body.weight(.semibold)).monospacedDigit()
                                Text("taught \(finder.taughtClicks[number] ?? 0)×")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if finder.isMatching {
                                    ProgressView().controlSize(.small)
                                } else if number != RallyDetector.otherTeam {
                                    Text("found in \(finder.taughtFound[number] ?? 0) rallies")
                                }
                                Button("Forget", role: .destructive) { finder.forget(number) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Looser")
                                Slider(value: $finder.matchSimilarity, in: 0.5...0.9)
                                Text("Stricter")
                            }
                            Text("Looser decides more players on its own but may mix up teammates; stricter asks about more.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        }
                    }
    }

    private var parsedNumber: Int? {
        guard let n = Int(numberText.trimmingCharacters(in: .whitespaces)), (0...99).contains(n) else { return nil }
        return n
    }

    private var picture: some View {
        GeometryReader { geo in
            let rect = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    // Drag anywhere on the picture to box a player by hand.
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                drawing = CGRect(x: min(value.startLocation.x, value.location.x),
                                                 y: min(value.startLocation.y, value.location.y),
                                                 width: abs(value.location.x - value.startLocation.x),
                                                 height: abs(value.location.y - value.startLocation.y))
                            }
                            .onEnded { _ in addDrawnBox(in: rect) })
                    if let drawing {
                        Rectangle()
                            .strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .frame(width: drawing.width, height: drawing.height)
                            .offset(x: drawing.minX, y: drawing.minY)
                            .allowsHitTesting(false)
                    }
                    ForEach(people.indices, id: \.self) { i in
                        // Vision boxes have a bottom-left origin.
                        let b = people[i].box
                        let r = CGRect(x: rect.minX + b.minX * rect.width,
                                       y: rect.minY + (1 - b.maxY) * rect.height,
                                       width: b.width * rect.width, height: b.height * rect.height)
                        Rectangle()
                            .strokeBorder(i == selected ? Color.yellow : Color.white.opacity(0.7),
                                          lineWidth: i == selected ? 3 : 1.5)
                            .background(i == selected ? Color.yellow.opacity(0.15) : Color.clear)
                            .contentShape(Rectangle())
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture { selected = i }
                    }
                }
                if loading || frame == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if people.isEmpty && drawing == nil {
                    Text("No players boxed in this frame. Drag a box around one, or step forward or back.")
                        .font(.callout)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func load() async {
        loading = true
        selected = nil
        let url = self.url, at = time
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, [(box: CGRect, print: [Float], color: [Float])], String) in
            guard let image = await VideoFrames.firstFrame(url: url, at: at, crop: nil) else {
                return (nil, [], "the frame couldn't be read")
            }
            let found = RallyDetector.people(in: image)
            return (image, found.people, found.note)
        }.value
        guard !Task.isCancelled else { return }
        Log.info("Teach a Player at \(Clip.format(at)): \(result.2)")
        frame = result.0
        people = result.1
        loading = false
    }

    /// Turns a hand-drawn box into a selectable player.
    private func addDrawnBox(in rect: CGRect) {
        guard let box = drawing, let frame, rect.width > 0, rect.height > 0 else { drawing = nil; return }
        drawing = nil
        // View (top-left origin) to Vision's unit, bottom-left origin.
        let unit = CGRect(x: (box.minX - rect.minX) / rect.width,
                          y: 1 - (box.maxY - rect.minY) / rect.height,
                          width: box.width / rect.width,
                          height: box.height / rect.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard unit.width > 0.01, unit.height > 0.02 else { return }
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> ([Float], [Float])? in
                guard let print = RallyDetector.featurePrint(of: frame, region: unit) else { return nil }
                // The torso is roughly the middle of a box drawn around a player.
                let torso = CGRect(x: unit.minX, y: unit.minY + unit.height * 0.42, width: unit.width, height: unit.height * 0.48)
                return (print, RallyDetector.jerseyColor(frame, torso: torso))
            }.value
            guard let found else {
                Log.error("Identify Players: no appearance for a drawn box")
                return
            }
            people.append((unit, found.0, found.1))
            selected = people.count - 1
        }
    }

    private func step(_ seconds: Double) {
        time = max(0, min(finder.duration, time + seconds))
    }

    private func teach() {
        guard let selected, people.indices.contains(selected), let number = parsedNumber else { return }
        finder.teach(number, print: people[selected].print, color: people[selected].color,
                     box: people[selected].box, time: time)
        self.selected = nil
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else { return CGRect(origin: .zero, size: size) }
        let aspect = CGFloat(frame.width) / CGFloat(frame.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// One person at a time, the ones on screen most first: "Who's this?" Each answer identifies
/// every stretch Cocut followed that person, so a handful of answers covers most of the match.
/// When a person is several stretches, close-ups of them are shown first so a mix-up of two
/// teammates can be unticked before the answer labels them all.
private struct WhoIsThisPane: View {
    let finder: RallyFinder
    let url: URL
    let onClose: () -> Void

    /// A close-up of one stretch of the current person.
    struct CloseUp: Identifiable {
        var track: Int
        var image: CGImage
        var id: Int { track }
    }

    /// Most stretches shown to confirm.
    static let confirmLimit = 9

    @State private var current: PlayerGrouping.Person?
    @State private var answered: Set<Int> = []
    @State private var picture: (image: CGImage, box: CGRect, time: Double)?
    /// One close-up per stretch, to confirm (when the person is several stretches).
    @State private var closeUps: [CloseUp] = []
    /// Extra views of a single stretch (when it's one stretch, nothing to confirm).
    @State private var views: [CGImage] = []
    /// Close-ups unticked: not this player.
    @State private var rejected: Set<Int> = []
    /// A close-up under the pointer, shown big in place of the frame.
    @State private var peek: CGImage?
    @State private var loading = false
    /// An answer split a person: wait for Cocut to group again before the next question.
    @State private var regrouping = false
    @State private var otherNumber = ""
    @State private var answeredCount = 0
    /// "Most players are sorted out": offered once per visit.
    @State private var showingDone = false
    @State private var offeredDone = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }
    #else
    private let wide = true
    #endif

    private var queue: [PlayerGrouping.Person] {
        finder.reviewQueue.filter { !$0.tracks.contains(where: answered.contains) }
    }

    /// Mostly done: the questions left would barely change any rally's list.
    private var isMostlyDone: Bool { finder.identifyMostlyDone }

    var body: some View {
        let queue = self.queue
        // How much of the player time during rallies is sorted out, and how many questions are
        // worth answering (the people covering most of what's left; the rest are glimpses).
        let share = finder.identifyProgress
        let worth = finder.suggestedQuestions
        let mostlyDone = isMostlyDone
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ProgressView(value: share)
                    .tint(mostlyDone ? .green : .accentColor)
                    .frame(maxWidth: 260)
                    .animation(.easeOut(duration: 0.6), value: share)
                Text("\(Int((share * 100).rounded()))% done")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.6), value: share)
                    .help("Of the players seen during rallies that Cocut couldn't place when you started. The people seen most come first, so the first answers count the most.")
                Spacer()
                if finder.isMatching { ProgressView().controlSize(.small) }
                Text(mostlyDone ? "Mostly done: the rest are brief glimpses" : "About \(worth) more worth answering")
                    .font(.callout)
                    .foregroundStyle(mostlyDone ? Color.green : Color.secondary)
                    .monospacedDigit()
            }
            if let current {
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            mainPicture
                                .hoverZoom(peek == nil)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(prompt(for: current))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // Close-ups scroll if there are many; the answers stay put below them.
                        VStack(alignment: .leading, spacing: 10) {
                            ScrollView {
                                closeUpArea(for: current)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                            answerButtons(for: current)
                        }
                        .frame(width: 500)
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        mainPicture
                            .hoverZoom(peek == nil)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(prompt(for: current))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                closeUpArea(for: current)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        answerButtons(for: current)
                    }
                    .frame(maxHeight: .infinity)
                }
            } else if regrouping || (finder.isMatching && queue.isEmpty) {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Sorting out who's who with your answer…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if queue.isEmpty {
                Text("Nothing left to ask about. Use Pick from a Frame for anyone still missing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if current == nil, !regrouping { current = queue.first } }
        .onChange(of: queue.first?.id) { _, _ in if current == nil, !regrouping { current = self.queue.first } }
        .onChange(of: finder.groupingRevision) { _, _ in
            if regrouping {
                regrouping = false
                current = self.queue.first
            }
            checkMostlyDone()
        }
        .task(id: current?.id) { await load() }
        .alert("Most players are sorted out", isPresented: $showingDone) {
            Button("Done") { onClose() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("Cocut can now list players on almost every rally. The questions left are brief glimpses that rarely change a rally's list.")
        }
    }

    /// Offers to stop once answers have made most of the rally time known (once per visit).
    private func checkMostlyDone() {
        guard answeredCount > 0, !offeredDone, !finder.isMatching, !regrouping, isMostlyDone else { return }
        offeredDone = true
        showingDone = true
    }

    /// Close-ups to confirm (several stretches), or other moments of the one stretch.
    @ViewBuilder private func closeUpArea(for person: PlayerGrouping.Person) -> some View {
        if closeUps.count >= 2 {
            confirmGrid(for: person)
        } else if let first = views.first {
            VStack(alignment: .leading, spacing: 6) {
                Text("Followed as one stretch, so these are the same box at different moments. If it shows different people, choose Skip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 6) {
                    Image(decorative: first, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .peekable(first, peek: $peek)
                    VStack(spacing: 6) {
                        ForEach(views.indices.dropFirst(), id: \.self) { i in
                            Image(decorative: views[i], scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 82)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .peekable(views[i], peek: $peek)
                        }
                    }
                }
            }
        }
    }

    /// "Same player?" One close-up per stretch, ticked; untick the ones that aren't them.
    @ViewBuilder private func confirmGrid(for person: PlayerGrouping.Person) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(person.tracks.count > closeUps.count
                 ? "The same player in all of these? Untick any who aren't. (\(closeUps.count) of \(person.tracks.count) times they were followed.)"
                 : "The same player in all of these? Untick any who aren't.")
                .font(.callout)
            #if os(macOS)
            Text("Point at a close-up to see it big on the left; point at the frame to magnify it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #else
            Text("Touch and hold a close-up to see it big; pinch the frame to zoom.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(closeUps) { closeUp in
                    let out = rejected.contains(closeUp.track)
                    Button {
                        if out { rejected.remove(closeUp.track) } else { rejected.insert(closeUp.track) }
                    } label: {
                        Image(decorative: closeUp.image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .background(Color.black)
                            .opacity(out ? 0.35 : 1)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: out ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, out ? Color.red : Color.green)
                                    .padding(4)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(out ? Color.red.opacity(0.8) : Color.clear, lineWidth: 2)
                            }
                            // Anywhere on the close-up ticks or unticks it, not just the picture.
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(out ? "Not this player: click to tick again" : "Click if this isn't the same player")
                    .peekable(closeUp.image, peek: $peek)
                }
            }
            if !rejected.isEmpty {
                Text(rejected.count == closeUps.count
                     ? "None of these is your answer: they'll be asked about again."
                     : "Your answer covers only the ticked ones. The unticked ones are noted as not this player\(person.tracks.count > closeUps.count ? ", and the rest are sorted out again" : "").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ number: Int) -> String {
        number == RallyDetector.otherTeam ? "the other team" : "#\(number)"
    }

    private func prompt(for p: PlayerGrouping.Person) -> String {
        let when = picture.map { "At \(Clip.format($0.time)). " } ?? ""
        let share = finder.totalPlayerFrames > 0 ? Double(p.frames) / Double(finder.totalPlayerFrames) : 0
        let size = share >= 0.005 ? "About \(max(1, Int((share * 100).rounded())))% of player time"
                                  : "Seen in \(p.tracks.count) stretch\(p.tracks.count == 1 ? "" : "es")"
        let read = p.reads.max(by: { $0.value < $1.value }).map { " Read as \(label($0.key)) \($0.value)×." } ?? ""
        if let guess = p.guess {
            return when + size + ". Looks a bit like \(label(guess)), but Cocut isn't sure." + read
        }
        return when + size + "." + read
    }

    /// Numbers to offer: the roster, or the numbers Cocut has read in this match.
    private var candidates: [Int] {
        let roster = finder.roster()
        if !roster.isEmpty { return roster.sorted() }
        let known = finder.people.compactMap { p -> Int? in
            (p.source == .read || p.source == .taught) ? p.number : nil
        }
        return Set(known.filter { $0 >= 0 }).sorted()
    }

    @ViewBuilder private func answerButtons(for d: PlayerGrouping.Person) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(candidates, id: \.self) { n in
                if n == d.guess {
                    numberButton(n).buttonStyle(.borderedProminent)
                } else {
                    numberButton(n).buttonStyle(.bordered)
                }
            }
        }
        HStack(spacing: 8) {
            TextField("Other #", text: $otherNumber)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { if let n = Int(otherNumber) { answerOther(n) } }
            Button("Use") { if let n = Int(otherNumber) { answerOther(n) } }
                .disabled(Int(otherNumber) == nil)
            Spacer(minLength: 8)
            Button("Not Our Team") { answer(RallyDetector.otherTeam) }
                .help("An opponent, referee or coach: players who look like this won't be listed")
            Button("Skip") { advance(skipping: true) }
                .help("Not a single player, a mix of people, or can't tell")
        }
        if answeredCount > 0 {
            Text("\(answeredCount) answered. Each answer covers every ticked stretch of that person, and teaches Cocut who looks like them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mainPicture: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if let peek {
                    Image(decorative: peek, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let picture {
                    let rect = fitted(picture.image, in: geo.size)
                    Image(decorative: picture.image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    let b = picture.box
                    Rectangle()
                        .strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: b.width * rect.width, height: b.height * rect.height)
                        .offset(x: rect.minX + b.minX * rect.width, y: rect.minY + (1 - b.maxY) * rect.height)
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// A number typed in. With a team roster, a number not on it joins it, so it's a button for
    /// the next questions. Without one it isn't added (a roster of one would leave everyone else
    /// off every rally); it becomes a button anyway once Cocut has grouped with the answer.
    private func answerOther(_ number: Int) {
        let roster = finder.roster()
        if number >= 0, !roster.isEmpty, !roster.contains(number) {
            finder.addToRoster(number)
            Log.info("Added #\(number) to the roster from Who's This?")
        }
        answer(number)
    }

    /// A jersey number as an answer button, all the same width so the grid lines up.
    private func numberButton(_ n: Int) -> some View {
        Button {
            answer(n)
        } label: {
            Text("#\(n)")
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
    }

    private func answer(_ number: Int) {
        guard let current else { return }
        otherNumber = ""
        peek = nil
        answeredCount += 1
        if rejected.isEmpty {
            finder.identify(current, as: number)
            advance(skipping: false)
            checkMostlyDone()
        } else {
            // A mix of people: only the ticked ones are this player. Ask again once Cocut has
            // grouped the rest with that to go on.
            let shown = Set(closeUps.map(\.track))
            let taught = finder.identify(current, as: number, confirmed: shown.subtracting(rejected), rejected: rejected)
            answered.formUnion(taught)
            self.current = nil
            regrouping = true
        }
    }

    private func advance(skipping: Bool) {
        guard let current else { return }
        if skipping { finder.skip(current) }
        answered.formUnion(current.tracks)
        self.current = finder.reviewQueue.first { !$0.tracks.contains(where: answered.contains) }
    }

    /// The frame where the person is biggest, and close-ups: one per stretch when they're several
    /// (to confirm), or other moments of the one stretch.
    private func load() async {
        rejected = []
        peek = nil
        guard let current else { picture = nil; closeUps = []; views = []; return }
        loading = true
        let frames = finder.sightings(of: current).sorted { $0.time < $1.time }
        // The best view: the biggest clear box (one player, shaped like one), not a sliver or a
        // box around several people.
        func quality(_ s: RallyDetector.PersonSighting) -> Double {
            Double(s.box.height) * (RallyDetector.isClear(s.box) ? 1 : 0.2)
        }
        guard let main = frames.max(by: { quality($0) < quality($1) }) else { loading = false; return }

        // Several stretches: the biggest view of each of the longest ones (the main one first).
        var perStretch: [RallyDetector.PersonSighting] = [main]
        let byTrack = Dictionary(grouping: frames.filter { $0.track != main.track }, by: \.track)
        // Every stretch gets a close-up so it can be unticked: its clearest view, and stretches
        // seen clearly first (a sliver is hard to judge).
        let others = byTrack.values.compactMap { stretch in stretch.max(by: { quality($0) < quality($1) }) }
            .sorted { a, b in
                let ca = RallyDetector.isClear(a.box), cb = RallyDetector.isClear(b.box)
                if ca != cb { return ca }
                return (byTrack[a.track]?.count ?? 0) > (byTrack[b.track]?.count ?? 0)
            }
        perStretch.append(contentsOf: others.prefix(Self.confirmLimit - 1))
        // One stretch: other clear moments of it, spread over time.
        var moments: [RallyDetector.PersonSighting] = []
        let clearFrames = frames.filter { RallyDetector.isClear($0.box) }
        let pool = clearFrames.count > 1 ? clearFrames : frames
        if perStretch.count < 2, pool.count > 1 {
            for k in 0..<4 where moments.count < 3 {
                let s = pool[min(pool.count - 1, k * (pool.count - 1) / 3)]
                if s.time != main.time, !moments.contains(where: { $0.time == s.time }) { moments.append(s) }
            }
        }
        let url = self.url
        let stretchViews = perStretch.count >= 2 ? perStretch : []
        let result = await Task.detached(priority: .userInitiated) { () -> ((CGImage, CGRect, Double)?, [CloseUp], [CGImage]) in
            var picture: (CGImage, CGRect, Double)?
            if let image = await VideoFrames.firstFrame(url: url, at: main.time, crop: nil) {
                picture = (image, main.box, main.time)
            }
            var closeUps: [CloseUp] = []
            for s in stretchViews {
                var image = picture?.0
                if s.time != main.time { image = await VideoFrames.firstFrame(url: url, at: s.time, crop: nil) }
                if let image, let crop = Self.crop(image, around: s.box) { closeUps.append(CloseUp(track: s.track, image: crop)) }
            }
            var views: [CGImage] = []
            if stretchViews.isEmpty {
                if let image = picture?.0, let crop = Self.crop(image, around: main.box) { views.append(crop) }
                for s in moments {
                    if let image = await VideoFrames.firstFrame(url: url, at: s.time, crop: nil),
                       let crop = Self.crop(image, around: s.box) {
                        views.append(crop)
                    }
                }
            }
            return (picture, closeUps, views)
        }.value
        guard !Task.isCancelled, current.id == self.current?.id else { return }
        picture = result.0.map { (image: $0.0, box: $0.1, time: $0.2) }
        closeUps = result.1
        views = result.2
        loading = false
    }

    /// The player's box (unit, bottom-left origin) with some room around it.
    nonisolated static func crop(_ image: CGImage, around box: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let padded = box.insetBy(dx: -box.width * 0.25, dy: -box.height * 0.1)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: padded.minX * w, y: (1 - padded.maxY) * h,
                            width: padded.width * w, height: padded.height * h).integral
        return image.cropping(to: pixels)
    }

    private func fitted(_ image: CGImage, in size: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: size) }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

private extension View {
    /// Shows `image` big while the pointer is over this (Mac), or in a preview on touch and hold
    /// (iPhone and iPad).
    func peekable(_ image: CGImage, peek: Binding<CGImage?>) -> some View {
        #if os(macOS)
        onHover { inside in
            if inside { peek.wrappedValue = image } else if peek.wrappedValue === image { peek.wrappedValue = nil }
        }
        #else
        contextMenu {
            Text("Close-up")
        } preview: {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(minWidth: 280, minHeight: 420)
        }
        #endif
    }
}

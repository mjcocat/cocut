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

    init(finder: RallyFinder, url: URL, time: Double, onClose: @escaping () -> Void) {
        self.finder = finder
        self.url = url
        self.onClose = onClose
        _time = State(initialValue: time)
    }

    var body: some View {
        @Bindable var finder = finder
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Mode", selection: $mode) {
                        Text("Who's This?").tag(Mode.whoIsThis)
                        Text("Pick from a Frame").tag(Mode.pick)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if mode == .whoIsThis {
                        WhoIsThisPane(finder: finder, url: url)
                    } else {
                        pickPane
                    }

                    identifiedList
                }
                .padding()
            }
            .navigationTitle("Identify Players")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 1080, minHeight: 640)
            #endif
            .toolbar {
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
private struct WhoIsThisPane: View {
    let finder: RallyFinder
    let url: URL

    @State private var current: PlayerGrouping.Person?
    @State private var answered: Set<Int> = []
    @State private var picture: (image: CGImage, box: CGRect, time: Double)?
    @State private var closeUps: [CGImage] = []
    @State private var loading = false
    @State private var otherNumber = ""
    @State private var answeredCount = 0

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }
    #else
    private let wide = true
    #endif

    var body: some View {
        let queue = finder.reviewQueue.filter { !$0.tracks.contains(where: answered.contains) }
        let share = finder.identifiedShare
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Who's this?").font(.title2.weight(.semibold))
                Spacer()
                if finder.isMatching { ProgressView().controlSize(.small) }
                Text("\(Int((share * 100).rounded()))% of player time identified")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: share)
                .tint(share >= 0.9 ? .green : .accentColor)
            if share >= 0.9 && current != nil {
                Text("Mostly done: what's left is mostly brief glimpses. Keep going only if a rally is missing someone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let current {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                  : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                layout {
                    VStack(alignment: .leading, spacing: 8) {
                        mainPicture
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(prompt(for: current))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 12) {
                        if let first = closeUps.first {
                            // The player up close where they're biggest, then from other stretches.
                            HStack(alignment: .top, spacing: 6) {
                                Image(decorative: first, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(spacing: 6) {
                                    ForEach(closeUps.indices.dropFirst(), id: \.self) { i in
                                        Image(decorative: closeUps[i], scale: 1)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 70)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                        answerButtons(for: current)
                    }
                    .frame(width: wide ? 340 : nil)
                }
            } else if queue.isEmpty {
                Text(finder.isMatching ? "Working out who everyone is…" : "Nothing left to ask about. Use Pick from a Frame for anyone still missing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onAppear { if current == nil { current = queue.first } }
        .onChange(of: queue.first?.id) { _, _ in if current == nil { current = queue.first } }
        .task(id: current?.id) { await load() }
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
                    Button("#\(n)") { answer(n) }.buttonStyle(.borderedProminent)
                } else {
                    Button("#\(n)") { answer(n) }.buttonStyle(.bordered)
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
                .onSubmit { if let n = Int(otherNumber) { answer(n) } }
            Button("Use") { if let n = Int(otherNumber) { answer(n) } }
                .disabled(Int(otherNumber) == nil)
        }
        HStack(spacing: 8) {
            Button("Not Our Team") { answer(RallyDetector.otherTeam) }
                .help("An opponent, referee or coach: players who look like this won't be listed")
            Button("Skip") { advance(skipping: true) }
                .help("Not a single player, a mix of people, or can't tell")
        }
        if answeredCount > 0 {
            Text("\(answeredCount) answered. Each answer covers every stretch of that person, and teaches Cocut who looks like them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mainPicture: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if let picture {
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

    private func answer(_ number: Int) {
        guard let current else { return }
        finder.identify(current, as: number)
        answeredCount += 1
        otherNumber = ""
        advance(skipping: false)
    }

    private func advance(skipping: Bool) {
        guard let current else { return }
        if skipping { finder.skip(current) }
        answered.formUnion(current.tracks)
        self.current = finder.reviewQueue.first { !$0.tracks.contains(where: answered.contains) }
    }

    /// The frame where the person is biggest, and close-ups from other stretches of them (so a
    /// mix-up of two people is easy to spot).
    private func load() async {
        guard let current else { picture = nil; closeUps = []; return }
        loading = true
        let frames = finder.sightings(of: current).sorted { $0.time < $1.time }
        guard let main = frames.max(by: { $0.box.height < $1.box.height }) else { loading = false; return }
        var others: [RallyDetector.PersonSighting] = []
        // The biggest view from each of the other longest stretches, then spread over time.
        let byTrack = Dictionary(grouping: frames.filter { $0.track != main.track }, by: \.track)
        for (_, stretch) in byTrack.sorted(by: { $0.value.count > $1.value.count }).prefix(3) {
            if let best = stretch.max(by: { $0.box.height < $1.box.height }) { others.append(best) }
        }
        if others.count < 3, frames.count > 1 {
            for k in 0..<4 where others.count < 3 {
                let s = frames[min(frames.count - 1, k * (frames.count - 1) / 3)]
                if s.time != main.time, !others.contains(where: { $0.time == s.time }) { others.append(s) }
            }
        }
        others.sort { $0.time < $1.time }
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) { () -> ((CGImage, CGRect, Double)?, [CGImage]) in
            var picture: (CGImage, CGRect, Double)?
            if let image = await VideoFrames.firstFrame(url: url, at: main.time, crop: nil) {
                picture = (image, main.box, main.time)
            }
            var crops: [CGImage] = []
            if let image = picture?.0, let crop = Self.crop(image, around: main.box) { crops.append(crop) }
            for s in others.prefix(3) {
                if let image = await VideoFrames.firstFrame(url: url, at: s.time, crop: nil),
                   let crop = Self.crop(image, around: s.box) {
                    crops.append(crop)
                }
            }
            return (picture, crops)
        }.value
        guard !Task.isCancelled, current.id == self.current?.id else { return }
        picture = result.0.map { (image: $0.0, box: $0.1, time: $0.2) }
        closeUps = result.1
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

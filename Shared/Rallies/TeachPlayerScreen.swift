import SwiftUI

/// Teach Cocut a player: click them on a frame of the match and type their number. Cocut then
/// finds them in every rally by how they look, which works even when their number can't be read
/// (a lone "1" in a slanted font, a number facing away).
struct TeachPlayerScreen: View {
    let finder: RallyFinder
    let url: URL
    let onClose: () -> Void

    @State private var time: Double
    @State private var frame: CGImage?
    @State private var people: [(box: CGRect, print: [Float])] = []
    @State private var loading = false
    @State private var selected: Int?
    @State private var numberText = ""

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
                    Text("Click a player, type their number, and choose **Teach**. Cocut then finds them in every rally by how they look. Teaching the same player at a couple of different moments (facing toward and away from the camera) gives better matches.")
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

                    if !finder.taught.isEmpty {
                        Divider()
                        Text("Taught players").font(.headline)
                        ForEach(finder.taught.keys.sorted(), id: \.self) { number in
                            HStack {
                                Text("#\(number)").font(.body.weight(.semibold)).monospacedDigit()
                                Text("\(finder.taught[number]?.count ?? 0) example\((finder.taught[number]?.count ?? 0) == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if finder.isMatching {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("found in \(finder.taughtFound[number] ?? 0) rallies")
                                }
                                Button("Forget", role: .destructive) { finder.forget(number) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Looser")
                                Slider(value: $finder.matchSimilarity, in: 0.6...0.95)
                                Text("Stricter")
                            }
                            Text("Looser finds more rallies but may mix up teammates; stricter misses some.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Teach a Player")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 820, minHeight: 640)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .task(id: time) { await load() }
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
                } else if people.isEmpty {
                    Text("No players found in this frame. Step forward or back.")
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
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, [(box: CGRect, print: [Float])]) in
            guard let image = await VideoFrames.firstFrame(url: url, at: at, crop: nil) else { return (nil, []) }
            return (image, RallyDetector.people(in: image))
        }.value
        guard !Task.isCancelled else { return }
        frame = result.0
        people = result.1
        loading = false
    }

    private func step(_ seconds: Double) {
        time = max(0, min(finder.duration, time + seconds))
    }

    private func teach() {
        guard let selected, people.indices.contains(selected), let number = parsedNumber else { return }
        finder.teach(number, print: people[selected].print)
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

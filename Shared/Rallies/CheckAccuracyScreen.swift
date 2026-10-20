import AVKit
import SwiftUI

/// Check Accuracy: mark which rallies a player is really in, and Cocut scores how well it lists
/// them: how often it's right when it lists them, and how many of their rallies it finds. The
/// score is shown for the current way of grouping players and for v0.21's, on the same answers,
/// so a change can be measured instead of judged by feel. Marks are saved with the match.
struct CheckAccuracyScreen: View {
    enum Show: Hashable { case all, unmarked, wrong }

    let finder: RallyFinder
    let onClose: () -> Void

    @State private var number: Int?
    @State private var numberText = ""
    @State private var show: Show = .all
    /// The rally being checked (playing, or last played).
    @State private var currentID: Rally.ID?
    @State private var playing = false
    @State private var copied = false
    @State private var condensedBefore = true

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }
    #else
    private let wide = true
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView { checkPane.padding(.vertical) }
                            .frame(minWidth: 420, maxWidth: 560)
                        rallyList
                    }
                    .padding(.horizontal)
                } else {
                    List {
                        Section { checkPane }
                        rallyRows
                    }
                }
            }
            .navigationTitle("Check Accuracy")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 1040, minHeight: 680)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
        .onAppear {
            finder.pause()
            // Play one rally at a time here, without jumping on to the next.
            condensedBefore = finder.watchCondensed
            finder.watchCondensed = false
            finder.startChecking()
            if number == nil { number = finder.markedNumbers.first ?? candidates.first }
        }
        .onDisappear {
            finder.pause()
            finder.watchCondensed = condensedBefore
            finder.stopChecking()
        }
        .onChange(of: finder.currentTime) { _, time in
            guard playing, let rally = currentRally else { return }
            if time >= rally.end - 0.05 {
                finder.pause()
                playing = false
            }
        }
    }

    // MARK: Video, marking and scores

    private var checkPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a player, then watch rallies and mark whether they're really in each one. Cocut scores its player lists against your marks, so changes to how it finds players can be measured.")
                .font(.callout)
                .foregroundStyle(.secondary)

            playerPicker

            ZStack {
                Color.black
                if let player = finder.player {
                    VideoPlayer(player: player)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            markBar
            scoreCard
        }
    }

    private var playerPicker: some View {
        HStack(spacing: 10) {
            Text("Player").font(.headline)
            Menu {
                ForEach(candidates, id: \.self) { n in
                    Button(finder.markedNumbers.contains(n) ? "#\(n) (marked)" : "#\(n)") { number = n }
                }
            } label: {
                Text(number.map { "#\($0)" } ?? "Choose")
                    .monospacedDigit()
            }
            .fixedSize()
            TextField("Other #", text: $numberText)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit(useTypedNumber)
            Button("Use", action: useTypedNumber)
                .disabled(typedNumber == nil)
            Spacer()
        }
    }

    /// In / Not in for the rally being checked, then on to the next unmarked one.
    @ViewBuilder private var markBar: some View {
        if let number, let rally = currentRally {
            let marked = finder.truthMark(number, in: rally)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Rally \(finder.number(of: rally)) · \(Clip.format(rally.start))")
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    Button {
                        play(rally)
                    } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                    }
                }
                HStack(spacing: 8) {
                    markButton("#\(number) is in it", systemImage: "checkmark", selected: marked == true, key: "i") {
                        mark(true, rally)
                    }
                    markButton("Not in it", systemImage: "xmark", selected: marked == false, key: "o") {
                        mark(false, rally)
                    }
                    Button("Next") { playNext(after: rally) }
                        .keyboardShortcut("n", modifiers: [])
                }
                #if os(macOS)
                Text("Keys: I is in it, O not in it, N next. Marking plays the next unmarked rally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        } else if number != nil {
            Button {
                if let first = visibleRallies.first { play(first) }
            } label: {
                Label("Start with the first rally", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(visibleRallies.isEmpty)
        }
    }

    private func markButton(_ title: String, systemImage: String, selected: Bool, key: Character,
                            action: @escaping () -> Void) -> some View {
        Group {
            if selected {
                Button(action: action) { Label(title, systemImage: systemImage) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Label(title, systemImage: systemImage) }
                    .buttonStyle(.bordered)
            }
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }

    @ViewBuilder private var scoreCard: some View {
        if let number {
            let now = finder.accuracy(of: number)
            VStack(alignment: .leading, spacing: 8) {
                if now.marked == 0 {
                    Text("No rallies marked for #\(number) yet. Mark a dozen or so, including some where Cocut lists #\(number) but they aren't really in it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(now.marked) rallies marked: #\(number) is in \(now.present), not in \(now.marked - now.present)")
                        .font(.headline)
                    scoreRow("Now", now)
                    if finder.hasBaseline {
                        scoreRow("v0.21", finder.accuracy(of: number, baseline: true))
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working out v0.21's score to compare…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Right: when Cocut lists #\(number) on a rally, how often they're really in it. Finds: of the rallies #\(number) is in, how many Cocut lists them on. Scores use your Who's This? answers so far.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Platform.copy(finder.accuracyReport(for: number))
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Results", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .help("Copy the scores and every marked rally as text, to paste into a message")
                        if finder.isMatching { ProgressView().controlSize(.small) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: now) { _, _ in copied = false }
        }
    }

    private func scoreRow(_ title: String, _ a: PlayerAccuracy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.subheadline.weight(.semibold)).frame(width: 48, alignment: .leading)
            stat("Right", a.precision)
            stat("Finds", a.recall)
            Text("\(a.right) right · \(a.wrong) wrong · \(a.missed) missed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 56, alignment: .leading)
    }

    // MARK: Rally list

    private var rallyList: some View {
        List(selection: Binding(get: { currentID }, set: { id in
            if let id, let rally = finder.rallies.first(where: { $0.id == id }) { play(rally) }
        })) {
            rallyRows
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: true))
        #endif
    }

    @ViewBuilder private var rallyRows: some View {
        Section {
            Picker("Show", selection: $show) {
                Text("All").tag(Show.all)
                Text("Not marked").tag(Show.unmarked)
                Text("Cocut wrong").tag(Show.wrong)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ForEach(visibleRallies) { rally in
                row(rally)
            }
            if visibleRallies.isEmpty {
                Text(show == .wrong ? "No marked rallies where Cocut is wrong." : "Nothing to show.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ rally: Rally) -> some View {
        let listed = number.map { finder.autoListed[rally.id]?.contains($0) ?? false } ?? false
        let mark = number.flatMap { finder.truthMark($0, in: rally) }
        return HStack(spacing: 10) {
            Image(systemName: rally.id == currentID && playing ? "speaker.wave.2.fill" : "play.circle")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rally \(finder.number(of: rally))").monospacedDigit()
                Text("\(Clip.format(rally.start)) · \(Int(rally.duration.rounded()))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(listed ? "Cocut lists" : "Not listed")
                .font(.caption)
                .foregroundStyle(mark != nil && mark != listed ? Color.red : Color.secondary)
            if let mark {
                Label(mark ? "In" : "Not in", systemImage: mark ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mark ? Color.green : Color.orange)
                    .frame(width: 70, alignment: .leading)
            } else {
                Text("–").foregroundStyle(.tertiary).frame(width: 70, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        #if os(iOS)
        .onTapGesture { play(rally) }
        #endif
        .contextMenu {
            if let number {
                Button("#\(number) Is In It") { finder.setTruth(true, number: number, in: rally) }
                Button("#\(number) Isn't In It") { finder.setTruth(false, number: number, in: rally) }
                Button("Clear Mark") { finder.setTruth(nil, number: number, in: rally) }
            }
        }
    }

    // MARK: Helpers

    private var currentRally: Rally? { finder.rallies.first { $0.id == currentID } }

    private var visibleRallies: [Rally] {
        guard let number else { return finder.rallies }
        switch show {
        case .all:
            return finder.rallies
        case .unmarked:
            return finder.rallies.filter { finder.truthMark(number, in: $0) == nil }
        case .wrong:
            return finder.rallies.filter { rally in
                guard let mark = finder.truthMark(number, in: rally) else { return false }
                return mark != (finder.autoListed[rally.id]?.contains(number) ?? false)
            }
        }
    }

    /// Numbers to offer: the roster, plus numbers on rallies and numbers already marked.
    private var candidates: [Int] {
        var all = finder.roster()
        all.formUnion(finder.playerCounts.map(\.number))
        all.formUnion(finder.markedNumbers)
        return all.filter { $0 >= 0 }.sorted()
    }

    private var typedNumber: Int? {
        guard let n = Int(numberText.trimmingCharacters(in: .whitespaces)), (0...99).contains(n) else { return nil }
        return n
    }

    private func useTypedNumber() {
        guard let n = typedNumber else { return }
        number = n
        numberText = ""
    }

    private func play(_ rally: Rally) {
        currentID = rally.id
        playing = true
        finder.play(rally)
    }

    private func mark(_ present: Bool, _ rally: Rally) {
        guard let number else { return }
        // Pressing the chosen answer again clears it.
        let current = finder.truthMark(number, in: rally)
        finder.setTruth(current == present ? nil : present, number: number, in: rally)
        if current != present { playNext(after: rally) }
    }

    /// Plays the next rally not yet marked for the player (or just the next one).
    private func playNext(after rally: Rally) {
        let list = finder.rallies
        guard let index = list.firstIndex(where: { $0.id == rally.id }) else { return }
        let later = list[(index + 1)...]
        if let number, let next = later.first(where: { finder.truthMark(number, in: $0) == nil }) {
            play(next)
        } else if let next = later.first {
            play(next)
        } else {
            finder.pause()
            playing = false
        }
    }
}

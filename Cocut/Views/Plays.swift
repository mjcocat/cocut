import SwiftUI

/// Switches for features that are built but turned off for now.
enum Features {
    /// Tagging plays ("Kill · #11"). Off: the UI is hidden; plays already on clips are kept.
    static let playTagging = false
}

// MARK: - Filter

/// What the clip list shows: everything, or clips matching a tag and/or a play ("Kills by #11").
struct ClipFilter: Equatable {
    var tagID: UUID?
    var player: Int?
    var action: PlayAction?

    var isActive: Bool { tagID != nil || player != nil || action != nil }

    func matches(_ clip: Clip) -> Bool {
        if let tagID, !clip.tags.contains(tagID) { return false }
        if let action {
            return clip.playList.contains { play in
                play.action == action && (player == nil || play.player == player)
            }
        }
        if let player { return clip.allPlayers.contains(player) }
        return true
    }

    @MainActor
    func description(in library: ClipLibrary) -> String {
        var parts: [String] = []
        switch (action, player) {
        case let (action?, player?): parts.append("\(action.plural) by \(library.playerLabel(player))")
        case let (action?, nil): parts.append(action.plural)
        case let (nil, player?): parts.append("clips with \(library.playerLabel(player))")
        case (nil, nil): break
        }
        if let tagID, let tag = library.tag(withID: tagID) {
            parts.append(parts.isEmpty ? "clips tagged “\(tag.name)”" : "tagged “\(tag.name)”")
        }
        return parts.joined(separator: " ")
    }
}

/// The filter button in the clip list footer: by player, by play, by tag. Player and play combine.
struct FilterMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ClipFilter

    private var library: ClipLibrary { model.library }

    /// Numbers on the roster or used in any play.
    private var players: [Int] {
        let used = library.clips.flatMap { $0.allPlayers }
        return Array(Set(used + library.roster.map(\.number))).sorted()
    }

    var body: some View {
        Menu {
            Button {
                filter = ClipFilter()
            } label: {
                checked("All Clips", !filter.isActive)
            }
            if !players.isEmpty {
                Section("Player") {
                    ForEach(players, id: \.self) { number in
                        Button {
                            filter.player = filter.player == number ? nil : number
                        } label: {
                            checked(library.playerLabel(number), filter.player == number)
                        }
                    }
                }
            }
            if Features.playTagging, !library.usedActions.isEmpty {
                Section("Play") {
                    ForEach(library.usedActions) { action in
                        Button {
                            filter.action = filter.action == action ? nil : action
                        } label: {
                            checked(action.plural, filter.action == action)
                        }
                    }
                }
            }
            if !library.tags.isEmpty {
                Section("Tag") {
                    ForEach(library.tags) { tag in
                        Button {
                            filter.tagID = filter.tagID == tag.id ? nil : tag.id
                        } label: {
                            checked(tag.name, filter.tagID == tag.id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only some clips: by player (#11), by play (Kills), or by tag. Pick a player and a play to combine them.")
        .disabled(players.isEmpty && (!Features.playTagging || library.usedActions.isEmpty) && library.tags.isEmpty)
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

// MARK: - Chips

struct PlayChip: View {
    let play: PlayTag
    var playerName: String? = nil
    var compact = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: play.action.symbol)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Remove this play")
            }
        }
        .font(compact ? .caption2.weight(.semibold) : .callout.weight(.medium))
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 1 : 4)
        .background(Capsule().fill(Color.accentColor.opacity(compact ? 0.14 : 0.18)))
        .foregroundStyle(Color.primary)
    }

    private var text: String {
        if compact {
            return play.player.map { "\(play.action.title) #\($0)" } ?? play.action.title
        }
        var t = play.label
        if let playerName, !playerName.isEmpty { t += " \(playerName)" }
        return t
    }
}

/// Plays on a clip, with an Add Play button (shown under the player).
struct PlayBar: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    @State private var adding = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.volleyball")
                .foregroundStyle(.secondary)
                .help("Plays: who did what in this clip. Use them to find every kill by #11. They aren't shown in the reel.")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(clip.playList) { play in
                        PlayChip(play: play,
                                 playerName: play.player.flatMap { model.library.player($0)?.name },
                                 onRemove: { model.library.removePlay(play, from: [clip.id]) })
                    }
                    Button {
                        adding = true
                    } label: {
                        Label(clip.playList.isEmpty ? "Add a Play" : "Add", systemImage: "plus")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .help("Tag a play, like Kill by #11 (⇧⌘P)")
                    .popover(isPresented: $adding, arrowEdge: .bottom) {
                        PlayEntry(clipIDs: [clip.id])
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Entry

/// Quick play entry: type "k11" and press Return, or click an action and a number.
struct PlayEntry: View {
    @Environment(AppModel.self) private var model
    let clipIDs: Set<Clip.ID>
    @State private var text = ""
    @State private var action: PlayAction?
    @State private var player: Int?
    @State private var added: [PlayTag] = []
    @FocusState private var fieldFocused: Bool

    private var library: ClipLibrary { model.library }
    private var parsed: PlayTag? { PlayTag.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(clipIDs.count == 1 ? "Add a Play" : "Add a Play to \(clipIDs.count) Clips")
                .font(.headline)

            HStack {
                TextField("k11, d5, b…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(addTyped)
                    .frame(width: 150)
                if let parsed {
                    Text(parsed.label)
                        .foregroundStyle(.secondary)
                } else if !text.isEmpty {
                    Text("Type a letter, then a number")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Play").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                    ForEach(PlayAction.allCases) { a in
                        choice(selected: action == a) {
                            Label(a.title, systemImage: a.symbol)
                        } tap: {
                            action = action == a ? nil : a
                            addIfReady()
                        }
                        .help("\(a.title) (type \(String(a.key).uppercased()))")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Player").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if library.roster.isEmpty {
                    Text("Type a number above (like k11), and it's added to your roster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                        ForEach(library.roster) { p in
                            choice(selected: player == p.number) {
                                Text(p.name.isEmpty ? "#\(p.number)" : "#\(p.number) \(p.name)")
                                    .lineLimit(1)
                            } tap: {
                                player = player == p.number ? nil : p.number
                                addIfReady()
                            }
                        }
                    }
                }
            }

            if !added.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    ForEach(added) { PlayChip(play: $0, compact: true) }
                }
                .font(.caption)
            }

            HStack {
                Text("K Kill · B Block · A Ace · D Dig · S Set · P Pass · V Serve · E Error")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let action, player == nil {
                    Button("Add \(action.title)") { add(PlayTag(action: action, player: nil)) }
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }

    private func choice<L: View>(selected: Bool, @ViewBuilder label: () -> L, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            label()
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func addTyped() {
        guard let parsed else { return }
        add(parsed)
        text = ""
    }

    private func addIfReady() {
        guard let action, let player else { return }
        add(PlayTag(action: action, player: player))
    }

    private func add(_ play: PlayTag) {
        library.addPlay(play, to: clipIDs)
        if !added.contains(play) { added.append(play) }
        action = nil
        player = nil
        fieldFocused = true
    }
}

// MARK: - Roster

/// The team's jersey numbers and names, so plays read "Kill · #11 Lilah".
struct RosterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var name = ""

    private var library: ClipLibrary { model.library }
    private var profile: PlayerProfile { model.profile.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Team Roster").font(.title2.weight(.semibold))
            Text("Jersey numbers for tagging plays. Numbers you type when tagging are added here automatically; add names to make them easier to read.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(library.roster) { p in
                    RosterRow(player: p)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180)

            HStack {
                TextField("#", text: $number)
                    .frame(width: 54)
                TextField("Name (optional)", text: $name)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(Int(number.filter(\.isNumber)) == nil)
            }
            .textFieldStyle(.roundedBorder)

            if let athlete = athleteNumber, library.player(athlete) == nil {
                Button("Add \(profile.firstName.isEmpty ? "your athlete" : profile.firstName) (#\(athlete)) from the Player Card") {
                    library.addPlayer(number: athlete, name: profile.firstName)
                }
                .buttonStyle(.link)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 460)
    }

    private var athleteNumber: Int? {
        Int(profile.clubNumber.filter(\.isNumber)) ?? Int(profile.schoolNumber.filter(\.isNumber))
    }

    private func add() {
        guard let n = Int(number.filter(\.isNumber)) else { return }
        library.addPlayer(number: n, name: name)
        number = ""
        name = ""
    }
}

private struct RosterRow: View {
    @Environment(AppModel.self) private var model
    let player: RosterPlayer
    @State private var name = ""

    var body: some View {
        HStack {
            Text("#\(player.number)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { model.library.renamePlayer(player.number, to: name) }
            let count = model.library.clips.filter { $0.playList.contains { $0.player == player.number } }.count
            Text(count == 1 ? "1 clip" : "\(count) clips")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.library.removePlayer(player.number)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from the roster (plays already tagged stay)")
        }
        .onAppear { name = player.name }
        .onDisappear {
            if name != player.name { model.library.renamePlayer(player.number, to: name) }
        }
    }
}

// MARK: - Players in a clip or rally

/// Jersey-number chips with remove buttons and a field to add one ("15", Return).
struct PlayerNumbersBar: View {
    let numbers: [Int]
    var name: (Int) -> String? = { _ in nil }
    let onAdd: (Int) -> Void
    let onRemove: (Int) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2")
                .foregroundStyle(.secondary)
                .help("Players in this clip. Filter by player to find every clip with them.")
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(numbers, id: \.self) { n in
                        HStack(spacing: 3) {
                            Text(name(n).map { "#\(n) \($0)" } ?? "#\(n)")
                                .monospacedDigit()
                            Button { onRemove(n) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove #\(n)")
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    TextField(numbers.isEmpty ? "Add a player #" : "Add #", text: $text)
                        .textFieldStyle(.plain)
                        .frame(width: numbers.isEmpty ? 100 : 50)
                        .onSubmit {
                            if let n = Int(text.filter(\.isNumber)), n < 1000 { onAdd(n) }
                            text = ""
                        }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

extension String {
    /// nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

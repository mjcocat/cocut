import AppKit
import SwiftUI

/// The three ways film gets into Cocut.
enum FilmSource: String, CaseIterable, Identifiable {
    case fullMatch, clips, online
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullMatch: return "A full match video"
        case .clips: return "Clips you already have"
        case .online: return "Film on YouTube or Hudl"
        }
    }

    var detail: String {
        switch self {
        case .fullMatch: return "From your camera or phone, or a Hudl download. Cocut finds the rallies and cuts out the dead time between them."
        case .clips: return "Short videos already on your Mac, like Hudl clips or phone videos. Import them, or drop them on the list."
        case .online: return "Play the film in your browser. Cocut records a clip each time you press play and saves it when you pause."
        }
    }

    var icon: String {
        switch self {
        case .fullMatch: return "figure.volleyball"
        case .clips: return "square.and.arrow.down.on.square"
        case .online: return "record.circle"
        }
    }

    var action: String {
        switch self {
        case .fullMatch: return "Find Rallies…"
        case .clips: return "Import Videos…"
        case .online: return "Record Region"
        }
    }
}

/// Basic athlete details from the New Project wizard, copied onto the Player Card.
struct AthleteBasics {
    var firstName = ""
    var lastName = ""
    var number = ""
    var position = ""
    var accent: CardAccent?
}

extension View {
    /// Starts getting film in the chosen way.
    @MainActor
    func startFilm(_ source: FilmSource, model: AppModel, openWindow: OpenWindowAction) {
        switch source {
        case .fullMatch:
            openWindow(id: "rallies")
            // Let the window appear before the file picker opens over it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.rallies.chooseMatch() }
        case .clips:
            Task { await model.importVideosWithPanel() }
        case .online:
            Task { await model.recordNewRegion() }
        }
    }
}

/// One big choice card.
struct FilmSourceCard: View {
    let source: FilmSource
    var selected = false
    var showsAction = true
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: source.icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(source == .online ? Color.red : Color.accentColor)
                .frame(height: 36)
            Text(source.title)
                .font(.headline)
            Text(source.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if showsAction {
                Button(source.action, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .tint(source == .online ? .red : .accentColor)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// What comes after the clips are in, as a simple path.
struct NextStepsPath: View {
    private let steps: [(String, String)] = [
        ("star", "Rate your best plays"),
        ("scope", "Spotlight your athlete"),
        ("person.text.rectangle", "Player Card"),
        ("play.rectangle", "Preview (⌘Y)"),
        ("square.and.arrow.up", "Export"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THEN")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits {
                HStack(spacing: 8) { items(arrows: true) }
                VStack(alignment: .leading, spacing: 6) { items(arrows: false) }
            }
        }
    }

    @ViewBuilder
    private func items(arrows: Bool) -> some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
            Label(step.1, systemImage: step.0)
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
            if arrows, i < steps.count - 1 {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The empty Clips screen: how to get film in, then what to do next.
struct GetStartedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image("Logo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Let's get some film in")
                            .font(.title.weight(.semibold))
                        Text("Pick whatever matches the video you have. You can mix them later.")
                            .foregroundStyle(.secondary)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) { cards }
                    VStack(spacing: 14) { cards }
                }

                if !model.canRecordLastRegion {
                    Text("Recording works from any app, even with the video in fullscreen: ⌥⌘N picks a region, ⌥⌘F records the full screen. Press the same keys to finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                NextStepsPath()
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { $0.isFileURL }
            guard !videos.isEmpty else { return false }
            Task { await model.importVideos(videos) }
            return true
        }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(FilmSource.allCases) { source in
            FilmSourceCard(source: source) {
                startFilm(source, model: model, openWindow: openWindow)
            }
            .frame(minWidth: 220)
            .disabled(source == .online && model.isBusy)
        }
    }
}

/// New Project: who it's for, then where the film comes from.
struct NewProjectWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called after the project is created, with the chosen way to add film (nil: decide later).
    let onCreate: (_ name: String, _ copyCard: Bool, _ athlete: AthleteBasics, _ source: FilmSource?) -> Void

    @State private var step = 1
    @State private var name = ""
    @State private var copyCard = false
    @State private var athlete = AthleteBasics()
    @State private var source: FilmSource?

    private var current: PlayerProfile { model.profile.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Project").font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(step) of 2").font(.callout).foregroundStyle(.secondary)
            }
            if step == 1 { who } else { film }

            HStack {
                if step == 2 {
                    Button("Back") { step = 1 }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if step == 1 {
                    Button("Next") { step = 2 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(source == nil ? "Create Project" : "Create and \(source!.action.replacingOccurrences(of: "…", with: ""))") {
                        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
                        dismiss()
                        onCreate(finalName, copyCard, athlete, source)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: step == 1 ? 480 : 760)
        .animation(.snappy, value: step)
        .onAppear {
            // Same athlete as the current project? Offer to start from their card.
            copyCard = !current.isEmpty
        }
    }

    private var defaultName: String {
        let first = copyCard ? current.firstName : athlete.firstName
        return first.isEmpty ? "New Reel" : "\(first)’s Reel"
    }

    // MARK: Step 1

    private var who: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A project is one highlight reel, with its own clips and Player Card. Make one per season, team or athlete.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $name, prompt: Text("Fall 2026 Club"))
                .textFieldStyle(.roundedBorder)

            if !current.isEmpty {
                Picker("Athlete", selection: $copyCard) {
                    Text("Same athlete: \(current.fullName)").tag(true)
                    Text("Someone else").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            if !copyCard {
                Text("ATHLETE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField("First name", text: $athlete.firstName)
                    TextField("Last name", text: $athlete.lastName)
                }
                HStack {
                    TextField("Jersey #", text: $athlete.number).frame(width: 90)
                    TextField("Position", text: $athlete.position, prompt: Text("Outside Hitter"))
                }
                HStack(spacing: 8) {
                    Text("Team color").foregroundStyle(.secondary)
                    ForEach(CardAccent.allCases) { accent in
                        Button {
                            athlete.accent = accent
                        } label: {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(athlete.accent == accent ? 0.9 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(accent.rawValue.capitalized)
                    }
                }
                Text("You can add a photo, stats and contact details later in Player Card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Step 2

    private var film: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where's your film? Pick one to start with. You can use the others any time.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(FilmSource.allCases) { option in
                    FilmSourceCard(source: option, selected: source == option, showsAction: false) {}
                        .onTapGesture { source = source == option ? nil : option }
                }
            }
            Text(source == nil ? "Not sure yet? Just create the project; the Clips screen shows these choices too."
                               : "Create opens \(source == .fullMatch ? "Find Rallies" : source == .clips ? "the file picker" : "region selection") right away.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

import AppKit
import SwiftUI

/// The ways film gets into Cocut.
enum FilmSource: String, CaseIterable, Identifiable {
    case fullMatch, youtube, clips, online
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullMatch: return "A full match video"
        case .youtube: return "A video on YouTube"
        case .clips: return "Clips on your Mac"
        case .online: return "Record from your screen"
        }
    }

    var detail: String {
        switch self {
        case .fullMatch: return "From your camera or phone. Cocut finds the rallies and cuts out the dead time between them."
        case .youtube: return "Download the whole video in full quality, then find its rallies or keep it as a clip."
        case .clips: return "Hudl downloads, phone videos and other short clips. Or drop them on this window."
        case .online: return "Play film in your browser, like Hudl. Cocut records a clip each time you press play."
        }
    }

    var icon: String {
        switch self {
        case .fullMatch: return "figure.volleyball"
        case .youtube: return "play.rectangle.fill"
        case .clips: return "square.and.arrow.down.on.square.fill"
        case .online: return "record.circle"
        }
    }

    /// Each way's own color, for its icon tile. Red stays for recording.
    var tint: Color {
        switch self {
        case .fullMatch: return .accentColor
        case .youtube: return .purple
        case .clips: return .teal
        case .online: return Design.record
        }
    }

    var action: String {
        switch self {
        case .fullMatch: return "Find Rallies…"
        case .youtube: return "Import from YouTube…"
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
        case .youtube:
            openWindow(id: "youtube")
        case .clips:
            Task { await model.importVideosWithPanel() }
        case .online:
            Task { await model.recordNewRegion() }
        }
    }
}

/// One way to get film in, as a large tile: the whole tile is the button.
struct FilmSourceCard: View {
    let source: FilmSource
    var selected = false
    /// Shows what clicking does ("Find Rallies →"); off where the tile only picks an option.
    var showsAction = true
    let onAction: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button(action: onAction) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Image(systemName: source.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(source.tint.gradient))
                    .shadow(color: source.tint.opacity(0.35), radius: hovering ? 10 : 6, y: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text(source.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(source.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if showsAction {
                    HStack(spacing: Design.Space.xs) {
                        Text(source.action.replacingOccurrences(of: "…", with: ""))
                        Image(systemName: "arrow.right")
                            .offset(x: hovering ? 3 : 0)
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(source.tint)
                }
            }
            .padding(Design.Space.xl)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
            .background(shape.fill(selected ? source.tint.opacity(0.12)
                                   : hovering ? Color.primary.opacity(0.075) : Design.panelFill))
            .overlay(shape.strokeBorder(selected ? source.tint : hovering ? source.tint.opacity(0.45) : Design.hairline,
                                        lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 && isEnabled }
        .motion(.snappy(duration: 0.18), value: hovering)
        .accessibilityHint(source.action.replacingOccurrences(of: "…", with: ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
            SectionLabel("Then")
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
            VStack(alignment: .leading, spacing: Design.Space.xl) {
                HStack(spacing: Design.Space.l) {
                    Image("Logo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Let's get some film in")
                            .font(.largeTitle.weight(.bold))
                        Text("Pick whatever matches the video you have. You can mix them later.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                // Two by two: big targets, easy to compare.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Design.Space.l),
                                    GridItem(.flexible(), spacing: Design.Space.l)],
                          spacing: Design.Space.l) {
                    ForEach(FilmSource.allCases) { source in
                        FilmSourceCard(source: source) {
                            startFilm(source, model: model, openWindow: openWindow)
                        }
                        .disabled(source == .online && model.isBusy)
                    }
                }

                if model.projects.projects.count > 1 {
                    OtherProjectsTile()
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
            .padding(Design.Space.xxl)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { $0.isFileURL }
            guard !videos.isEmpty else { return false }
            Task { await model.importVideos(videos) }
            return true
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
        .frame(width: step == 1 ? 480 : 640)
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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(FilmSource.allCases) { option in
                    FilmSourceCard(source: option, selected: source == option, showsAction: false) {
                        source = source == option ? nil : option
                    }
                }
            }
            Text(source == nil ? "Not sure yet? Just create the project; the Clips screen shows these choices too."
                               : "Create opens \(source == .fullMatch ? "Find Rallies" : source == .youtube ? "Import from YouTube" : source == .clips ? "the file picker" : "region selection") right away.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

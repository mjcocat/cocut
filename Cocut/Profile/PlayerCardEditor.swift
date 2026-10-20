import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerCardEditor: View {
    @Environment(AppModel.self) private var model
    @State private var previewKind: CardKind = .intro
    /// Which reel shape the preview shows; starts on the export's shape.
    @State private var previewShape: ReelShape?

    private var store: ProfileStore { model.profile }

    var body: some View {
        @Bindable var store = self.store
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headshotSection
                    section("Player") {
                        row {
                            field("First name", $store.profile.firstName)
                            field("Last name", $store.profile.lastName)
                        }
                        row {
                            field("Position", $store.profile.position, prompt: "Outside Hitter")
                            field("Class of", $store.profile.gradYear, prompt: "2027")
                        }
                        row {
                            field("Height", $store.profile.height, prompt: "5'10\"")
                            field("Age", $store.profile.age)
                        }
                    }
                    section("Teams") {
                        row {
                            field("Club team", $store.profile.clubTeam, prompt: "Club name & team")
                            field("Club #", $store.profile.clubNumber).frame(width: 90)
                        }
                        row {
                            field("High school", $store.profile.highSchool)
                            field("School #", $store.profile.schoolNumber).frame(width: 90)
                        }
                        row {
                            field("Hometown", $store.profile.hometown, prompt: "City, State")
                            field("GPA", $store.profile.gpa).frame(width: 90)
                        }
                    }
                    statsSection
                    section("Contact (shown on the cards)") {
                        field("Email", $store.profile.email)
                        row {
                            field("Phone", $store.profile.phone)
                            field("Social", $store.profile.social, prompt: "@handle")
                        }
                    }
                    section("Design") {
                        designPicker("Layout", options: CardStyle.allCases, selected: store.profile.style,
                                     title: \.title) { style in
                            var p = store.profile
                            p.style = style
                            return p
                        } select: { store.profile.style = $0 }
                        designPicker("Theme", options: CardTheme.allCases, selected: store.profile.theme,
                                     title: \.title) { theme in
                            var p = store.profile
                            p.theme = theme
                            return p
                        } select: { store.profile.theme = $0 }
                        accentPicker
                        Toggle("End the reel with a contact card", isOn: $store.profile.showEndCard)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 480)

            preview
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Player Card")
        .navigationSubtitle(store.profile.fullName.isEmpty ? "Intro and end cards for the reel" : store.profile.fullName)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 14) {
            Picker("Card", selection: $previewKind) {
                Text("Intro Card").tag(CardKind.intro)
                Text("End Card").tag(CardKind.end)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Picker("Shape", selection: Binding(
                get: { previewShape ?? model.exporter.options.shape },
                set: { previewShape = $0 }
            )) {
                Text("Widescreen").tag(ReelShape.widescreen)
                Text("Phone 9:16").tag(ReelShape.vertical)
                Text("Feed 4:5").tag(ReelShape.portrait)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .help("Phone reels use tall versions of the cards")

            Spacer(minLength: 0)

            // The card, with its caption right under it.
            let canvas = PlayerCardView.designCanvas(for: previewShape ?? model.exporter.options.shape)
            GeometryReader { geo in
                let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
                PlayerCardView(profile: store.profile, headshot: store.headshot, kind: previewKind, canvasSize: canvas)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
                    .mediaFrame(radius: Design.Radius.large)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
            .padding(.horizontal, Design.Space.xl)

            Text(previewKind == .intro
                 ? "Opens the reel. Blank fields are left off the card."
                 : (store.profile.showEndCard ? "Closes the reel with your contact details." : "The end card is turned off."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Design thumbnails

    /// A row of live mini cards, one per option; click to choose.
    private func designPicker<T: Hashable & Identifiable>(_ label: String, options: [T], selected: T,
                                                          title: KeyPath<T, String>,
                                                          profile: @escaping (T) -> PlayerProfile,
                                                          select: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(options) { option in
                        let isOn = option == selected
                        Button {
                            select(option)
                        } label: {
                            VStack(spacing: 4) {
                                PlayerCardView(profile: profile(option), headshot: store.headshot, kind: .intro)
                                    .scaleEffect(120 / PlayerCardView.canvas.width, anchor: .topLeading)
                                    .frame(width: 120, height: 67.5, alignment: .topLeading)
                                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                                            .strokeBorder(isOn ? Color.accentColor : Design.hairline,
                                                          lineWidth: isOn ? 2.5 : 1)
                                    )
                                Text(option[keyPath: title])
                                    .font(.caption)
                                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(option[keyPath: title])
                        .accessibilityLabel("\(label): \(option[keyPath: title])")
                        .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 3)
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Sections

    private var headshotSection: some View {
        HStack(spacing: 16) {
            ZStack {
                if let image = store.headshot {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 120)
            .mediaFrame()
            .accessibilityLabel(store.headshot == nil ? "No headshot. Drop a photo here." : "Headshot")
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                store.setHeadshot(from: url)
                return true
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Headshot").font(.headline)
                Text("A clear, well-lit photo. Drag one here or choose a file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Photo…") { choosePhoto() }
                    if store.headshot != nil {
                        Button("Remove", role: .destructive) { store.removeHeadshot() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        @Bindable var store = self.store
        return section("Stats & measurables") {
            ForEach($store.profile.stats) { $stat in
                HStack {
                    TextField("Label", text: $stat.label, prompt: Text("Approach touch"))
                    TextField("Value", text: $stat.value, prompt: Text("9'10\""))
                    Button {
                        store.profile.stats.removeAll { $0.id == stat.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
            }
            Button {
                store.addStat()
            } label: {
                Label("Add Stat", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(store.profile.stats.count >= 6)
        }
    }

    private var accentPicker: some View {
        @Bindable var store = self.store
        let isCustom = store.profile.customAccent != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Team color")
                Spacer()
                ColorPicker(selection: Binding(
                    get: { store.profile.accentColor },
                    set: { store.profile.customAccent = $0.hexString }
                ), supportsOpacity: false) {
                    Text("Custom")
                }
                .help("Pick any color, such as your club's exact color")
                if isCustom {
                    Text(store.profile.customAccent ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ForEach(CardAccent.allCases) { accent in
                    Button {
                        store.profile.accent = accent
                        store.profile.customAccent = nil
                    } label: {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle()
                                .strokeBorder(Color.primary.opacity(!isCustom && store.profile.accent == accent ? 0.9 : 0),
                                              lineWidth: 2)
                                .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(accent.rawValue.capitalized)
                }
            }
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s + 2) {
            SectionLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Design.Space.l - 2, radius: Design.Radius.large)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Headshot"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.setHeadshot(from: url)
        }
    }
}

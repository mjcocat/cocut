import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerCardEditor: View {
    @Environment(AppModel.self) private var model
    @State private var previewKind: CardKind = .intro

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
                        Picker("Layout", selection: $store.profile.style) {
                            ForEach(CardStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
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

            GeometryReader { geo in
                let canvas = PlayerCardView.canvas
                let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
                PlayerCardView(profile: store.profile, headshot: store.headshot, kind: previewKind)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)

            Text(previewKind == .intro
                 ? "Opens the reel. Blank fields are left off the card."
                 : (store.profile.showEndCard ? "Closes the reel with your contact details." : "The end card is turned off."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .padding(.top, 18)
        .background(Color(nsColor: .underPageBackgroundColor))
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
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

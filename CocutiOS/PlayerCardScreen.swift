import PhotosUI
import SwiftUI

/// The reel's intro card (and optional end card): details, headshot, layout, theme, team color.
struct PlayerCardScreen: View {
    @Environment(IOSModel.self) private var model
    @State private var headshotItem: PhotosPickerItem?
    @State private var previewKind: CardKind = .intro

    var body: some View {
        @Bindable var store = model.profile
        NavigationStack {
            Form {
                Section {
                    CardPreview(profile: store.profile, headshot: store.headshot, kind: previewKind)
                        .listRowInsets(EdgeInsets())
                    if store.profile.showEndCard {
                        Picker("Preview", selection: $previewKind) {
                            Text("Intro Card").tag(CardKind.intro)
                            Text("End Card").tag(CardKind.end)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Headshot") {
                    PhotosPicker(selection: $headshotItem, matching: .images) {
                        Label(store.headshot == nil ? "Choose a Photo…" : "Change Photo…", systemImage: "person.crop.square")
                    }
                    if store.headshot != nil {
                        Button("Remove Photo", role: .destructive) { store.removeHeadshot() }
                    }
                }

                Section("Athlete") {
                    TextField("First name", text: $store.profile.firstName)
                    TextField("Last name", text: $store.profile.lastName)
                    TextField("Position", text: $store.profile.position)
                    TextField("Class of", text: $store.profile.gradYear).keyboardType(.numberPad)
                    TextField("Height", text: $store.profile.height)
                    TextField("Age", text: $store.profile.age).keyboardType(.numberPad)
                    TextField("Hometown", text: $store.profile.hometown)
                    TextField("GPA", text: $store.profile.gpa).keyboardType(.decimalPad)
                }

                Section("Teams") {
                    TextField("Club team", text: $store.profile.clubTeam)
                    TextField("Club jersey #", text: $store.profile.clubNumber).keyboardType(.numberPad)
                    TextField("High school", text: $store.profile.highSchool)
                    TextField("School jersey #", text: $store.profile.schoolNumber).keyboardType(.numberPad)
                }

                Section("Stats") {
                    ForEach($store.profile.stats) { $stat in
                        HStack {
                            TextField("Label, e.g. Approach touch", text: $stat.label)
                            TextField("Value", text: $stat.value)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .onDelete { store.profile.stats.remove(atOffsets: $0) }
                    if store.profile.stats.count < 6 {
                        Button("Add Stat", systemImage: "plus") { store.addStat() }
                    }
                }

                Section("Look") {
                    Picker("Layout", selection: $store.profile.style) {
                        ForEach(CardStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Theme", selection: $store.profile.theme) {
                        ForEach(CardTheme.allCases) { Text($0.title).tag($0) }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(CardAccent.allCases) { accent in
                                let isOn = store.profile.customAccent == nil && store.profile.accent == accent
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: isOn ? 3 : 0))
                                    .onTapGesture {
                                        store.profile.accent = accent
                                        store.profile.customAccent = nil
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    ColorPicker("Custom team color", selection: Binding(
                        get: { store.profile.accentColor },
                        set: { store.profile.customAccent = $0.hexString }
                    ), supportsOpacity: false)
                }

                Section {
                    Toggle("End card with contact details", isOn: $store.profile.showEndCard)
                    if store.profile.showEndCard {
                        TextField("Email", text: $store.profile.email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        TextField("Phone", text: $store.profile.phone).keyboardType(.phonePad)
                        TextField("Social", text: $store.profile.social)
                            .textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle("Player Card")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProjectMenu() }
            }
            .onChange(of: headshotItem) { _, item in
                guard let item else { return }
                headshotItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        model.profile.setHeadshot(image)
                    }
                }
            }
        }
    }
}

/// The card at its 1920×1080 design size, scaled to fit.
struct CardPreview: View {
    let profile: PlayerProfile
    let headshot: UIImage?
    let kind: CardKind

    var body: some View {
        let canvas = PlayerCardView.canvas
        GeometryReader { geo in
            let scale = geo.size.width / canvas.width
            PlayerCardView(profile: profile, headshot: headshot, kind: kind)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .clipped()
    }
}

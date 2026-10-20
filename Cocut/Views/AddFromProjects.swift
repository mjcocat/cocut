import SwiftUI

/// Add from Other Projects: browse the clips of every other project, filter to the best plays
/// (rating, player, tag), pick, and copy them in. Made for a season reel pulled from one
/// project per tournament.
struct AddFromProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Another project and its clips (read only).
    private struct Source: Identifiable {
        let project: Project
        let library: ClipLibrary
        var id: UUID { project.id }
    }

    @State private var sources: [Source] = []
    /// Picked clips, by `key(for:in:)`.
    @State private var selected: Set<String> = []
    @State private var minStars = 0
    @State private var player: Int?
    @State private var tagName: String?
    @State private var asSections = true
    @State private var copying: (done: Int, total: Int)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sources.isEmpty {
                ContentUnavailableView("No Other Projects", systemImage: "folder",
                                       description: Text("Make a project for each tournament, then come back here to pull the best plays into one reel."))
            } else {
                filters
                Divider()
                list
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 640)
        .onAppear(perform: load)
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.m) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text("Add from Other Projects").font(.title2.weight(.semibold))
                Text("Pick clips from your other projects, like each tournament, for a season reel. They're copied in with their trim, rating, tags and players, so changes here don't touch the originals.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Design.Space.l + 4)
    }

    private var filters: some View {
        HStack(spacing: Design.Space.m) {
            Picker("Rating", selection: $minStars) {
                Text("Any rating").tag(0)
                Text("★★★ and up").tag(3)
                Text("★★★★ and up").tag(4)
                Text("★★★★★ only").tag(5)
            }
            .fixedSize()
            Picker("Player", selection: $player) {
                Text("Any player").tag(Int?.none)
                ForEach(allPlayers, id: \.self) { n in
                    Text(model.library.playerLabel(n)).tag(Int?.some(n))
                }
            }
            .fixedSize()
            .disabled(allPlayers.isEmpty)
            Picker("Tag", selection: $tagName) {
                Text("Any tag").tag(String?.none)
                ForEach(allTags, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .fixedSize()
            .disabled(allTags.isEmpty)
            Spacer()
            let shown = sources.flatMap { s in visible(s).map { key(for: $0, in: s) } }.filter { !copied.contains($0) }
            Button(shown.allSatisfy(selected.contains) && !shown.isEmpty ? "Deselect All" : "Select All") {
                if shown.allSatisfy(selected.contains) { selected.subtract(shown) } else { selected.formUnion(shown) }
            }
            .disabled(shown.isEmpty)
        }
        .labelsHidden()
        .padding(.horizontal, Design.Space.l + 4)
        .padding(.vertical, Design.Space.s + 2)
    }

    private var list: some View {
        let groups = sources.map { ($0, visible($0)) }.filter { !$0.1.isEmpty }
        return Group {
            if groups.isEmpty {
                ContentUnavailableView("No Clips Match", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Try a lower rating or another player. Rate clips in each project (1–5 in the list) to find your best plays here."))
            } else {
                List {
                    ForEach(groups, id: \.0.id) { group in
                        let (source, clips) = group
                        Section {
                            ForEach(clips) { clip in row(clip, in: source) }
                        } header: {
                            HStack {
                                Text(source.project.name)
                                Text("\(clips.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ clip: Clip, in source: Source) -> some View {
        let key = key(for: clip, in: source)
        let already = copied.contains(key)
        let isOn = selected.contains(key)
        return HStack(spacing: Design.Space.m) {
            Toggle("Add \(clip.title)", isOn: Binding(
                get: { isOn || already },
                set: { on in if on { selected.insert(key) } else { selected.remove(key) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(already)
            ClipThumbnail(url: source.library.url(for: clip), crop: clip.unitCrop)
                .frame(width: 96, height: 54)
                .mediaFrame(radius: Design.Radius.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title).font(.headline).lineLimit(1)
                HStack(spacing: Design.Space.xs + 2) {
                    Text(clip.durationText).monospacedDigit()
                    if clip.stars > 0 {
                        Text(String(repeating: "★", count: clip.stars)).foregroundStyle(.yellow)
                    }
                    if !clip.allPlayers.isEmpty {
                        Text(clip.allPlayers.sorted().map { "#\($0)" }.joined(separator: " "))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Design.Space.s)
            if already { Pill(text: "Already added") }
        }
        .opacity(already ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !already else { return }
            if isOn { selected.remove(key) } else { selected.insert(key) }
        }
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var footer: some View {
        let picked = pickedClips
        return HStack(spacing: Design.Space.m) {
            if let copying {
                ProgressView(value: Double(copying.done), total: Double(max(1, copying.total)))
                    .frame(width: 180)
                Text("Copying \(copying.done) of \(copying.total)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Toggle("Put each project in its own section", isOn: $asSections)
                    .help("A section per project, named after it, so the reel is organized by event. Turn on its divider card for a title between events.")
            }
            Spacer()
            if !picked.isEmpty, copying == nil {
                Text("\(picked.count) \(picked.count == 1 ? "clip" : "clips") · \(Clip.format(picked.reduce(0) { $0 + $1.effectiveDuration }))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(copying != nil)
            Button(picked.isEmpty ? "Add Clips" : "Add \(picked.count) \(picked.count == 1 ? "Clip" : "Clips")") { add() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || copying != nil)
        }
        .padding(.horizontal, Design.Space.l + 4)
        .padding(.vertical, Design.Space.m)
    }

    // MARK: Data

    /// Already in this project.
    private var copied: Set<String> { model.library.copiedOrigins }

    /// Where a clip first came from (copies of copies count as the same clip).
    private func origin(of clip: Clip, in source: Source) -> ClipOrigin {
        clip.origin ?? ClipOrigin(projectID: source.project.id, clipID: clip.id, projectName: source.project.name)
    }

    private func key(for clip: Clip, in source: Source) -> String { origin(of: clip, in: source).key }

    private func visible(_ source: Source) -> [Clip] {
        source.library.clips.filter { clip in
            clip.stars >= minStars
                && (player.map { clip.allPlayers.contains($0) } ?? true)
                && (tagName.map { name in clip.tags.contains { source.library.tag(withID: $0)?.name == name } } ?? true)
        }
    }

    private var allPlayers: [Int] {
        Set(sources.flatMap { $0.library.clips.flatMap(\.allPlayers) }).sorted()
    }

    private var allTags: [String] {
        Set(sources.flatMap { $0.library.tags.map(\.name) }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var pickedClips: [Clip] {
        sources.flatMap { s in s.library.clips.filter { selected.contains(key(for: $0, in: s)) } }
    }

    private func load() {
        let store = model.projects
        sources = store.projects
            .filter { $0.id != store.currentID }
            .map { Source(project: $0, library: ClipLibrary(directory: store.directory(for: $0))) }
            .filter { !$0.library.clips.isEmpty }
        // Start on the best plays when there are rated ones.
        if sources.contains(where: { $0.library.clips.contains { $0.stars >= 4 } }) { minStars = 4 }
    }

    private func add() {
        let groups = sources.compactMap { s -> (title: String, requests: [ClipLibrary.CopyRequest])? in
            let requests = s.library.clips
                .filter { selected.contains(key(for: $0, in: s)) && !copied.contains(key(for: $0, in: s)) }
                .map { clip in
                    ClipLibrary.CopyRequest(clip: clip, file: s.library.url(for: clip),
                                            tags: clip.tags.compactMap { s.library.tag(withID: $0) },
                                            origin: origin(of: clip, in: s))
                }
            return requests.isEmpty ? nil : (s.project.name, requests)
        }
        let total = groups.reduce(0) { $0 + $1.requests.count }
        guard total > 0 else { return }
        copying = (0, total)
        Task {
            let added = await model.library.addCopies(groups, sections: asSections) { done in
                copying = (done, total)
            }
            Log.info("Added \(added) clips from \(groups.count) other project(s)")
            model.requestedSection = .clips
            dismiss()
        }
    }
}

/// A clip's first frame (cropped like the clip), loaded lazily.
private struct ClipThumbnail: View {
    let url: URL
    let crop: CGRect?
    @State private var image: CGImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .task(id: url) { image = await ThumbnailLoader.shared.thumbnail(for: url, crop: crop) }
    }
}

/// On Get Started and in an empty project: pull clips from other projects.
struct OtherProjectsTile: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button {
            model.showingAddFromProjects = true
        } label: {
            HStack(spacing: Design.Space.l) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.gradient))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clips from your other projects").font(.headline).foregroundStyle(.primary)
                    Text("Making a season reel? Pull the best plays from each tournament's project.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: Design.Space.xs) {
                    Text("Add from Other Projects")
                    Image(systemName: "arrow.right").offset(x: hovering ? 3 : 0)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            }
            .padding(Design.Space.l + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? Color.primary.opacity(0.075) : Design.panelFill))
            .overlay(shape.strokeBorder(hovering ? Color.orange.opacity(0.45) : Design.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.snappy(duration: 0.18), value: hovering)
    }
}

import AppKit
import SwiftUI

struct ClipsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Selected rows: clips and/or section headings.
    @State private var selection: Set<UUID> = []
    @State private var deleting: [Clip] = []
    @State private var filter = ClipFilter()
    @State private var showingRoster = false
    @State private var sectionPrompt: SectionPrompt?
    @State private var sectionName = ""
    @State private var tagPrompt: TagPrompt?
    @State private var tagName = ""
    @State private var showingTagManager = false
    @State private var renaming: Clip?
    @State private var renameText = ""

    private var library: ClipLibrary { model.library }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasScreenPermission {
                PermissionBanner()
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
            }

            if library.items.isEmpty {
                emptyState
            } else {
                HSplitView {
                    ClipListPane(selection: $selection, deleting: $deleting, filter: $filter,
                                 actions: actions)
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 580)
                    detail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Clips")
        .navigationSubtitle(subtitle)
        .overlay(alignment: .bottom) {
            if model.phase == .stopping {
                SavingToast()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.phase)
        .onAppear {
            if selection.isEmpty, let first = library.clips.first?.id { selection = [first] }
        }
        .onChange(of: library.recentlyAddedID) { _, newID in
            if let newID { selection = [newID] }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })
        ) {
            Button("Move to Trash", role: .destructive) { performDelete() }
        } message: {
            Text("You can restore clips from the Trash in Finder.")
        }
        .alert(sectionPrompt?.title ?? "New Section",
               isPresented: Binding(get: { sectionPrompt != nil }, set: { if !$0 { sectionPrompt = nil } })) {
            TextField("Section name", text: $sectionName, prompt: Text("Kills, Blocks, Serves…"))
            Button("Add") { commitSection() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sectionPrompt?.message ?? "")
        }
        .alert("New Tag",
               isPresented: Binding(get: { tagPrompt != nil }, set: { if !$0 { tagPrompt = nil } })) {
            TextField("Tag name", text: $tagName, prompt: Text("Kill, Ace, Dig, Best…"))
            Button("Add") { commitTag() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((tagPrompt?.clipIDs.isEmpty ?? true)
                 ? "Tags help you sort and find clips. They never appear in the exported reel."
                 : "The new tag is added to the selected clips.")
        }
        .alert("Rename Clip",
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Clip name", text: $renameText, prompt: Text("Kill vs. Thunder"))
            Button("Rename") { commitRename() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names show in the list, and as captions if you turn on clip names when exporting.")
        }
        .sheet(isPresented: $showingTagManager) {
            TagManagerView()
        }
        .sheet(isPresented: $showingRoster) {
            RosterView()
        }
    }

    // MARK: Detail routing

    @ViewBuilder
    private var detail: some View {
        let clipIDs = selection.filter { library.clip(withID: $0) != nil }
        if selection.count == 1, let id = selection.first, let section = library.section(withID: id) {
            SectionDetailPane(section: section)
        } else if clipIDs.count > 1 {
            MultiSelectionPane(clips: library.clips.filter { clipIDs.contains($0.id) },
                               deleting: $deleting, actions: actions,
                               clearSelection: { selection = [] })
        } else {
            ClipDetailPane(clip: library.clip(withID: clipIDs.first), deleting: $deleting, actions: actions)
        }
    }

    private var actions: ClipActions {
        ClipActions(
            newSection: { ids in
                sectionName = ""
                sectionPrompt = SectionPrompt(clipIDs: ids)
            },
            newTag: { ids in
                tagName = ""
                tagPrompt = TagPrompt(clipIDs: ids)
            },
            manageTags: { showingTagManager = true },
            managePlayers: { showingRoster = true },
            select: { selection = $0 },
            rename: { clip in
                renameText = clip.title
                renaming = clip
            }
        )
    }

    private func commitRename() {
        guard let clip = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != clip.title { library.rename(clip, to: name) }
        renaming = nil
    }

    private func commitSection() {
        guard let prompt = sectionPrompt else { return }
        let name = sectionName.trimmingCharacters(in: .whitespaces)
        let section = library.addSection(title: name.isEmpty ? "New Section" : name, gathering: prompt.clipIDs)
        sectionPrompt = nil
        if prompt.clipIDs.isEmpty { selection = [section.id] }
    }

    private func commitTag() {
        guard let prompt = tagPrompt else { return }
        if let tag = library.addTag(name: tagName), !prompt.clipIDs.isEmpty {
            library.toggleTag(tag.id, on: prompt.clipIDs)
        }
        tagPrompt = nil
    }

    // MARK: Delete

    private var deleteTitle: String {
        deleting.count == 1
            ? "Move “\(deleting[0].title)” to the Trash?"
            : "Move \(deleting.count) clips to the Trash?"
    }

    private func performDelete() {
        let ids = Set(deleting.map(\.id))
        let clips = library.clips
        let firstIndex = clips.firstIndex { ids.contains($0.id) } ?? 0
        library.delete(deleting)
        deleting = []
        selection.subtract(ids)
        let remaining = library.clips
        if selection.isEmpty, !remaining.isEmpty {
            selection = [remaining[min(firstIndex, remaining.count - 1)].id]
        }
    }

    private var subtitle: String {
        let count = library.clips.count
        guard count > 0 else { return "" }
        let included = library.includedClips.count
        let reel = included == count ? "" : " · \(included) in reel"
        return "\(count) \(count == 1 ? "clip" : "clips")\(reel) · \(Clip.format(library.totalDuration)) total"
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            VStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                Text("No Clips Yet")
                    .font(.title2.weight(.semibold))
            }
        } description: {
            Text("Open game film on YouTube or Hudl and select the video. Cocut records a clip each time you press play and saves it when you pause.")
        } actions: {
            Button {
                Task { await model.recordNewRegion() }
            } label: {
                Label("Record Region", systemImage: "record.circle")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.isBusy)

            Button("Import Videos…") {
                Task { await model.importVideosWithPanel() }
            }
            .buttonStyle(.borderless)

            Button("Find Rallies in a Full Match…") {
                openWindow(id: "rallies")
            }
            .buttonStyle(.borderless)

            Text("From any app, even with the video in fullscreen: ⌥⌘N picks a region, ⌥⌘F records the full screen, ⌥⌘R repeats the last region. Press the same keys to finish.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { $0.isFileURL }
            guard !videos.isEmpty else { return false }
            Task { await model.importVideos(videos) }
            return true
        }
    }
}

private struct SectionPrompt {
    let clipIDs: Set<UUID>
    var title: String { clipIDs.isEmpty ? "New Section" : "New Section from \(clipIDs.count) Clip\(clipIDs.count == 1 ? "" : "s")" }
    var message: String {
        clipIDs.isEmpty
            ? "Sections group clips, like Kills or Blocks. Drag clips under a section to add them."
            : "The selected clips are gathered under the new section."
    }
}

private struct TagPrompt {
    let clipIDs: Set<UUID>
}

/// Actions the panes can ask the clips screen to start (prompts and sheets live there).
struct ClipActions {
    var newSection: (Set<UUID>) -> Void
    var newTag: (Set<UUID>) -> Void
    var manageTags: () -> Void
    var managePlayers: () -> Void
    var select: (Set<UUID>) -> Void
    var rename: (Clip) -> Void
}

// MARK: - List

private struct ClipListPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: Set<UUID>
    @Binding var deleting: [Clip]
    @Binding var filter: ClipFilter
    let actions: ClipActions

    private var library: ClipLibrary { model.library }

    /// Reordering is only possible on the full list, not a filtered one.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard !filter.isActive else { return nil }
        let library = self.library
        return { source, destination in library.move(fromOffsets: source, toOffset: destination) }
    }

    private var displayItems: [LibraryItem] {
        guard filter.isActive else { return library.items }
        return library.items.filter { item in item.clip.map { filter.matches($0) } ?? false }
    }

    var body: some View {
        VStack(spacing: 0) {
            if filter.isActive {
                let tint = filter.tagID.flatMap { library.tag(withID: $0)?.color.color } ?? Color.accentColor
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(tint)
                    Text("Showing \(filter.description(in: library)) · \(displayItems.count) \(displayItems.count == 1 ? "clip" : "clips")")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Show All") { filter = ClipFilter() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(tint.opacity(0.1))
                Divider()
            }

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(displayItems) { item in
                        row(for: item)
                            .tag(item.id)
                            .id(item.id)
                    }
                    .onMove(perform: moveAction)
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(for: ids)
                }
                .onDeleteCommand {
                    let clips = library.clips.filter { selection.contains($0.id) }
                    if !clips.isEmpty { deleting = clips }
                }
                // 1–5 rate the selected clips; 0 clears.
                .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
                    let ids = Set(library.clips.filter { selection.contains($0.id) }.map(\.id))
                    guard !ids.isEmpty, let n = Int(press.characters) else { return .ignored }
                    library.setRating(n, for: ids)
                    return .handled
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let videos = urls.filter { $0.isFileURL }
                    guard !videos.isEmpty else { return false }
                    Task { await model.importVideos(videos) }
                    return true
                }
                .onChange(of: library.recentlyAddedID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.snappy) { proxy.scrollTo(newID, anchor: .center) }
                }
            }

            Divider()
            footer
        }
    }

    @ViewBuilder
    private func row(for item: LibraryItem) -> some View {
        switch item {
        case .section(let section):
            SectionRow(section: section,
                       clipCount: library.clips(in: section.id).count,
                       isNewClipsTarget: library.newClipsSectionID == section.id,
                       canReorder: !filter.isActive)
        case .clip(let clip):
            ClipRow(clip: clip,
                    canReorder: !filter.isActive,
                    number: library.number(of: clip),
                    url: library.url(for: clip),
                    tags: clip.tags.compactMap { library.tag(withID: $0) },
                    deleteCount: selection.contains(clip.id) ? max(1, library.clips.filter { selection.contains($0.id) }.count) : 1,
                    onDelete: {
                        // Deleting one of several selected clips deletes the whole selection.
                        if selection.contains(clip.id) {
                            deleting = library.clips.filter { selection.contains($0.id) }
                        } else {
                            deleting = [clip]
                        }
                    })
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let clips = library.clips.filter { ids.contains($0.id) }
        let sections = library.sections.filter { ids.contains($0.id) }
        let clipIDs = Set(clips.map(\.id))

        if !clips.isEmpty {
            if clips.count == 1, let clip = clips.first {
                Button("Rename…") { actions.rename(clip) }
                Divider()
            }
            Menu("Rating") {
                ForEach((1...5).reversed(), id: \.self) { n in
                    Button(String(repeating: "★", count: n)) { library.setRating(n, for: clipIDs) }
                }
                Divider()
                Button("No Rating") { library.setRating(0, for: clipIDs) }
            }
            if clips.count == 1, let clip = clips.first, clip.isIncluded {
                Button("Preview Reel from This Clip") {
                    model.preview.startAt(clipID: clip.id)
                    openWindow(id: "preview")
                }
                Divider()
            }
            if clips.contains(where: { !$0.isIncluded }) {
                Button("Include in Reel") { library.setIncluded(clipIDs, true) }
            }
            if clips.contains(where: { $0.isIncluded }) {
                Button("Leave Out of Reel") { library.setIncluded(clipIDs, false) }
            }
            Divider()
            TagsMenu(clipIDs: clipIDs, actions: actions)
            Menu("Move to Section") {
                Button("Top of List (No Section)") { library.moveClips(clipIDs, toSection: nil) }
                if !library.sections.isEmpty { Divider() }
                ForEach(library.sections) { section in
                    Button(section.title) { library.moveClips(clipIDs, toSection: section.id) }
                }
            }
            Button("New Section from Selection…") { actions.newSection(clipIDs) }
            Divider()
            if clips.count == 1, let clip = clips.first {
                Button("Show in Finder") { library.revealInFinder(clip) }
            }
            Button(clips.count == 1 ? "Move to Trash…" : "Move \(clips.count) Clips to Trash…",
                   role: .destructive) { deleting = clips }
        } else if sections.count == 1, let section = sections.first {
            Button("Rename…") { actions.select([section.id]) }
            Toggle("Show Divider Card in Reel", isOn: Binding(
                get: { section.showCard },
                set: { library.setSectionCard(section.id, $0) }
            ))
            Toggle("Add New Clips Here", isOn: Binding(
                get: { library.newClipsSectionID == section.id },
                set: { library.newClipsSectionID = $0 ? section.id : nil }
            ))
            Divider()
            Button("Delete Section", role: .destructive) { library.deleteSection(section.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Section…") { actions.newSection([]) }
                Button("New Tag…") { actions.newTag([]) }
                Divider()
                Button("Manage Tags…") { actions.manageTags() }
                Button("Team Roster…") { actions.managePlayers() }
                Divider()
                Button("Order by Rating (Best First)") { library.orderByRating() }
                    .disabled(!library.clips.contains { $0.rating != nil })
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a section or a tag")

            FilterMenu(filter: $filter)

            if let target = library.section(withID: library.newClipsSectionID) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                    Text("New clips → \(target.title)")
                        .lineLimit(1)
                    Button {
                        library.newClipsSectionID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Add new clips at the end of the list instead")
                }
            } else {
                Text(!filter.isActive ? "Drag to reorder · drop videos to import" : "Reordering is off while filtering")
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                Task { await model.importVideosWithPanel() }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Add video files, such as Hudl downloads (⌘I)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Tag toggles for the given clips, plus "New Tag…".
private struct TagsMenu: View {
    @Environment(AppModel.self) private var model
    let clipIDs: Set<UUID>
    let actions: ClipActions

    var body: some View {
        let library = model.library
        let clips = library.clips.filter { clipIDs.contains($0.id) }
        Menu("Tags") {
            ForEach(library.tags) { tag in
                let count = clips.filter { $0.tags.contains(tag.id) }.count
                Button {
                    library.toggleTag(tag.id, on: clipIDs)
                } label: {
                    if count == clips.count, count > 0 {
                        Label(tag.name, systemImage: "checkmark")
                    } else if count > 0 {
                        Label(tag.name, systemImage: "minus")
                    } else {
                        Text(tag.name)
                    }
                }
            }
            if !library.tags.isEmpty { Divider() }
            Button("New Tag…") { actions.newTag(clipIDs) }
        }
    }
}

private struct SectionRow: View {
    let section: ReelSection
    let clipCount: Int
    let isNewClipsTarget: Bool
    var canReorder = true

    var body: some View {
        HStack(spacing: 8) {
            if canReorder { DragHandle(help: "Drag to move this section and its clips") }
            Image(systemName: "rectangle.split.1x2")
                .foregroundStyle(Color.accentColor)
            Text(section.title.uppercased())
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .tracking(1)
                .lineLimit(1)
            Text("\(clipCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if isNewClipsTarget {
                Image(systemName: "arrow.down.to.line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("New clips are added to this section")
            }
            if section.showCard {
                Label("Card", systemImage: "rectangle.on.rectangle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .help("A divider card introduces this section in the reel")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// The ☰ grip on a row: shows that rows can be dragged to reorder.
private struct DragHandle: View {
    let help: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? Color.primary : Color.secondary.opacity(0.55))
            .frame(width: 16, height: 28)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop() } }
            .help(help)
    }
}

private struct ClipRow: View {
    let clip: Clip
    var canReorder = true
    let number: Int
    let url: URL
    let tags: [ClipTag]
    var deleteCount = 1
    var onDelete: () -> Void = {}

    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if canReorder { DragHandle(help: "Drag to change where this clip plays in the reel") }
            Text("\(number)")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Color.black
                .frame(width: 112, height: 63)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(clip.durationText).monospacedDigit()
                    if clip.isTrimmed {
                        Image(systemName: "scissors")
                            .help("Trimmed")
                    }
                    Text("·")
                    Text(clip.createdAt.formatted(date: .omitted, time: .shortened))
                    if clip.stars > 0 {
                        Text(String(repeating: "★", count: clip.stars))
                            .foregroundStyle(.yellow)
                            .help("\(clip.stars) star\(clip.stars == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                let plays = Features.playTagging ? clip.playList : []
                if !tags.isEmpty || !plays.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(plays.prefix(2)) { play in
                            PlayChip(play: play, compact: true)
                        }
                        ForEach(tags.prefix(plays.isEmpty ? 3 : 2)) { tag in
                            TagChip(tag: tag, compact: true)
                        }
                        let hidden = max(0, plays.count - 2) + max(0, tags.count - (plays.isEmpty ? 3 : 2))
                        if hidden > 0 {
                            Text("+\(hidden)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if !clip.isIncluded {
                Text("Left out")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                    .help("Not included when you export the reel")
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(deleteCount > 1 ? "Move the \(deleteCount) selected clips to the Trash (⌫)" : "Move this clip to the Trash (⌫)")
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .opacity(clip.isIncluded ? 1 : 0.5)
        .padding(.vertical, 5)
        .onHover { hovering = $0 }
        .task(id: "\(url.path)|\(String(describing: clip.unitCrop))") {
            image = await ThumbnailLoader.shared.thumbnail(for: url, crop: clip.unitCrop)
        }
    }
}

struct TagChip: View {
    let tag: ClipTag
    var compact = false
    var selected = true

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tag.color.color)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
            Text(tag.name)
                .lineLimit(1)
        }
        .font(compact ? .caption2.weight(.medium) : .callout.weight(.medium))
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 1 : 4)
        .background(
            Capsule().fill(tag.color.color.opacity(selected ? (compact ? 0.15 : 0.22) : 0.0))
        )
        .overlay(
            Capsule().strokeBorder(tag.color.color.opacity(selected ? 0 : 0.5), lineWidth: 1)
        )
        .foregroundStyle(selected ? Color.primary : Color.secondary)
    }
}

// MARK: - Clip detail

private struct ClipDetailPane: View {
    @Environment(AppModel.self) private var model
    let clip: Clip?
    @Binding var deleting: [Clip]
    let actions: ClipActions

    @State private var titleDraft = ""
    @State private var trimRequest = 0
    @State private var cropMessage: String?
    @FocusState private var titleFocused: Bool

    private var library: ClipLibrary { model.library }

    var body: some View {
        if let clip {
            VStack(spacing: 0) {
                PlayerView(
                    url: library.url(for: clip),
                    trimStart: clip.trimStart,
                    trimEnd: clip.trimEnd,
                    crop: clip.cropRect,
                    isActive: !model.isBusy,
                    trimRequest: trimRequest,
                    onTrimmed: { start, end in library.setTrim(clip, start: start, end: end) }
                )
                // Rebuild the player when the clip or its trim changes.
                .id("\(clip.id)-\(clip.trimStart ?? -1)-\(clip.trimEnd ?? -1)-\(String(describing: clip.crop))")
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Clip name", text: $titleDraft)
                                .textFieldStyle(.plain)
                                .font(.title3.weight(.semibold))
                                .focused($titleFocused)
                                .onSubmit { commitTitle(clip) }
                                .onChange(of: titleFocused) { _, focused in
                                    if !focused { commitTitle(clip) }
                                }
                            Text(details(clip))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        StarRating(rating: clip.stars, size: 15) { library.setRating($0, for: [clip.id]) }
                            .help("Rate this play (or press 1–5 in the list). Order by Rating puts the best first.")

                        Toggle("In Reel", isOn: Binding(
                            get: { clip.isIncluded },
                            set: { library.setIncluded([clip.id], $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Include this clip when exporting the highlight reel")

                        if clip.isTrimmed {
                            Button("Reset Trim") {
                                library.setTrim(clip, start: nil, end: nil)
                            }
                            .help("Use the whole clip again")
                        }
                        Button {
                            trimRequest += 1
                        } label: {
                            Label("Trim", systemImage: "scissors")
                        }
                        .help("Drag the yellow handles to choose where the clip starts and ends")

                        Button(role: .destructive) {
                            deleting = [clip]
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Move this clip to the Trash (⌫)")

                        Menu {
                            Menu("Move to Section") {
                                Button("Top of List (No Section)") { library.moveClips([clip.id], toSection: nil) }
                                ForEach(library.sections) { section in
                                    Button(section.title) { library.moveClips([clip.id], toSection: section.id) }
                                }
                            }
                            if clip.crop != nil {
                                Button("Show the Full Recording") { library.removeCrop(clip.id) }
                            } else {
                                Button("Crop to the Video") { cropToVideo(clip) }
                            }
                            Button("Rename…") { titleFocused = true }
                            Button("Show in Finder") { library.revealInFinder(clip) }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { deleting = [clip] }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }

                    tagBar(clip)
                    if Features.playTagging {
                        PlayBar(clip: clip)
                    }
                    PlayerNumbersBar(numbers: clip.playerList,
                                     name: { library.player($0)?.name.nilIfEmpty },
                                     onAdd: { library.setPlayers(clip.playerList + [$0], for: clip.id) },
                                     onRemove: { n in library.setPlayers(clip.playerList.filter { $0 != n }, for: clip.id) })

                    if let cropMessage {
                        Label(cropMessage, systemImage: "viewfinder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if clip.crop != nil {
                        HStack(spacing: 6) {
                            Label("Cropped to the video", systemImage: "crop")
                                .foregroundStyle(.secondary)
                            Button("Show Full Recording") { library.removeCrop(clip.id) }
                                .buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onAppear { titleDraft = clip.title }
            .onChange(of: clip.id) { _, _ in titleDraft = clip.title }
        } else {
            ContentUnavailableView("Select a Clip", systemImage: "play.rectangle",
                                   description: Text("Choose a clip on the left to watch, rename, tag or trim it."))
        }
    }

    private func cropToVideo(_ clip: Clip) {
        cropMessage = "Looking for the video…"
        Task {
            let found = await library.autoCrop(clip.id, force: true)
            cropMessage = found ? nil : "No smaller video area found: the whole recording is changing."
            if !found {
                try? await Task.sleep(for: .seconds(4))
                cropMessage = nil
            }
        }
    }

    private func tagBar(_ clip: Clip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .help("Tags help you sort clips. They aren't shown in the reel.")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(library.tags) { tag in
                        Button {
                            library.toggleTag(tag.id, on: [clip.id])
                        } label: {
                            TagChip(tag: tag, selected: clip.tags.contains(tag.id))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        actions.newTag([clip.id])
                    } label: {
                        Label(library.tags.isEmpty ? "Add a Tag" : "New", systemImage: "plus")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func details(_ clip: Clip) -> String {
        var parts = [clip.durationText]
        if clip.isTrimmed { parts.append("trimmed from \(Clip.format(clip.duration))") }
        if let section = library.sectionContaining(clip.id) { parts.append(section.title) }
        parts.append(clip.resolutionText)
        parts.append(clip.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func commitTitle(_ clip: Clip) {
        if titleDraft.trimmingCharacters(in: .whitespaces).isEmpty {
            titleDraft = clip.title
        } else if titleDraft != clip.title {
            library.rename(clip, to: titleDraft)
        }
    }
}

// MARK: - Section detail

private struct SectionDetailPane: View {
    @Environment(AppModel.self) private var model
    let section: ReelSection

    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private var library: ClipLibrary { model.library }

    var body: some View {
        let clips = library.clips(in: section.id)
        let included = clips.filter(\.isIncluded).count
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SECTION")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Section name", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.largeTitle.weight(.bold))
                        .focused($titleFocused)
                        .onSubmit { commit() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commit() } }
                    Text("\(clips.count) clip\(clips.count == 1 ? "" : "s") · \(included) in the reel · drag clips under this heading in the list to add them")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { section.showCard },
                        set: { library.setSectionCard(section.id, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show a divider card before this section")
                            Text("A short title card in the exported reel, in the Player Card's colors.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    PlayerCardView(profile: model.profile.profile, headshot: model.profile.headshot,
                                   kind: .section(titleDraft.isEmpty ? section.title : titleDraft))
                        .scaleEffect(480 / PlayerCardView.canvas.width, anchor: .topLeading)
                        .frame(width: 480, height: 270, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(section.showCard ? 1 : 0.35)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        .overlay {
                            if !section.showCard {
                                Text("Card off")
                                    .font(.headline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .glassEffect(.regular, in: Capsule())
                            }
                        }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { library.newClipsSectionID == section.id },
                        set: { library.newClipsSectionID = $0 ? section.id : nil }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add new recordings and imports here")
                            Text("Handy while you work through one kind of play at a time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))

                HStack {
                    Spacer()
                    Button("Delete Section", role: .destructive) { library.deleteSection(section.id) }
                        .help("Removes the heading only; its clips stay in the list")
                }
            }
            .padding(24)
        }
        .onAppear { titleDraft = section.title }
        .onChange(of: section.id) { _, _ in titleDraft = section.title }
    }

    private func commit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            titleDraft = section.title
        } else if trimmed != section.title {
            library.renameSection(section.id, to: trimmed)
        }
    }
}

// MARK: - Multiple selection

private struct MultiSelectionPane: View {
    @Environment(AppModel.self) private var model
    let clips: [Clip]
    @Binding var deleting: [Clip]
    let actions: ClipActions
    let clearSelection: () -> Void
    @State private var addingPlay = false

    var body: some View {
        let library = model.library
        let ids = Set(clips.map(\.id))
        ContentUnavailableView {
            Label("\(clips.count) Clips Selected", systemImage: "square.stack.3d.up")
        } description: {
            Text("\(Clip.format(clips.reduce(0) { $0 + $1.effectiveDuration })) total")
        } actions: {
            if !library.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(library.tags) { tag in
                        let all = clips.allSatisfy { $0.tags.contains(tag.id) }
                        Button {
                            library.toggleTag(tag.id, on: ids)
                        } label: {
                            TagChip(tag: tag, selected: all)
                        }
                        .buttonStyle(.plain)
                        .help(all ? "Remove “\(tag.name)” from these clips" : "Tag these clips “\(tag.name)”")
                    }
                }
            }
            HStack {
                Button("New Tag…") { actions.newTag(ids) }
                if Features.playTagging {
                    Button("Add a Play…") { addingPlay = true }
                        .popover(isPresented: $addingPlay, arrowEdge: .bottom) {
                            PlayEntry(clipIDs: ids)
                        }
                }
                Button("New Section from Selection…") { actions.newSection(ids) }
            }
            Button(role: .destructive) {
                deleting = clips
            } label: {
                Label("Move \(clips.count) Clips to Trash…", systemImage: "trash")
            }
            .controlSize(.large)
            Button("Deselect All", action: clearSelection)
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Tag manager

private struct TagManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        let library = model.library
        VStack(alignment: .leading, spacing: 14) {
            Text("Tags").font(.title2.weight(.semibold))
            Text("Tags are for sorting and finding clips while you work. They're never shown in the exported reel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if library.tags.isEmpty {
                Text("No tags yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(library.tags) { tag in
                        TagManagerRow(tag: tag)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(minHeight: 160, maxHeight: 280)
            }

            HStack {
                TextField("New tag", text: $newName, prompt: Text("Kill, Ace, Dig…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func add() {
        if model.library.addTag(name: newName) != nil { newName = "" }
    }
}

private struct TagManagerRow: View {
    @Environment(AppModel.self) private var model
    let tag: ClipTag
    @State private var name = ""

    var body: some View {
        let library = model.library
        let count = library.clips.filter { $0.tags.contains(tag.id) }.count
        HStack(spacing: 10) {
            Menu {
                ForEach(TagColor.allCases) { color in
                    Button {
                        library.setTagColor(tag.id, color)
                    } label: {
                        Label(color.rawValue.capitalized, systemImage: tag.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Circle().fill(tag.color.color).frame(width: 14, height: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { library.renameTag(tag.id, to: name) }

            Text("\(count) clip\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                library.deleteTag(tag.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this tag (clips are kept)")
        }
        .onAppear { name = tag.name }
    }
}

// MARK: - Supporting views

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Screen Recording permission needed")
                    .font(.headline)
                Text("Turn on Cocut in System Settings › Privacy & Security › Screen & System Audio Recording, then click Reopen. macOS only applies the change after Cocut restarts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                Button("Open Settings") { model.requestPermission() }
                    .controlSize(.large)
                Button("Reopen Cocut") { model.relaunch() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

struct SavingToast: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Saving clip…")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: Capsule())
    }
}

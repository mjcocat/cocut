import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The clip library: reorder, include/leave out, rate, rename, delete, import.
struct ClipsScreen: View {
    @Environment(IOSModel.self) private var model
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var importStatus: String?
    @State private var newSectionName = ""
    @State private var namingSection = false

    var body: some View {
        let library = model.library
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Clips Yet", systemImage: "film.stack")
                    } description: {
                        Text("Import clips from Photos or Files, or use Find Rallies to cut a full match into its rallies.")
                    } actions: {
                        Button("Import from Photos") { showingPhotos = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(library.items) { item in
                            switch item {
                            case .section(let section):
                                Text(section.title)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            case .clip(let clip):
                                NavigationLink(value: clip.id) {
                                    ClipRow(clip: clip, url: library.url(for: clip))
                                }
                                .swipeActions(edge: .leading) {
                                    Button(clip.isIncluded ? "Leave Out" : "Include",
                                           systemImage: clip.isIncluded ? "eye.slash" : "eye") {
                                        library.setIncluded([clip.id], !clip.isIncluded)
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                        .onMove { library.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            let doomed = offsets.compactMap { library.items[$0].clip }
                            let sections = offsets.compactMap { library.items[$0].section }
                            if !doomed.isEmpty { library.delete(doomed) }
                            for s in sections { library.deleteSection(s.id) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Clips")
            .navigationDestination(for: Clip.ID.self) { id in
                ClipDetailScreen(clipID: id)
            }
            .safeAreaInset(edge: .bottom) {
                if let importStatus {
                    Label(importStatus, systemImage: "arrow.down.circle")
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                } else if !library.clips.isEmpty {
                    Text("\(library.includedClips.count) of \(library.clips.count) clips in the reel · \(Clip.format(library.includedClips.reduce(0) { $0 + $1.effectiveDuration }))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProjectMenu() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !library.items.isEmpty { EditButton() }
                    Menu {
                        Button("Import from Photos…", systemImage: "photo.on.rectangle") { showingPhotos = true }
                        Button("Import from Files…", systemImage: "folder") { showingFiles = true }
                        Divider()
                        Button("New Section…", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            newSectionName = ""
                            namingSection = true
                        }
                        Button("Best Rated First", systemImage: "star") { library.orderByRating() }
                            .disabled(library.clips.isEmpty)
                        Divider()
                        Button("Undo \(library.undoName ?? "")", systemImage: "arrow.uturn.backward") { library.undo() }
                            .disabled(!library.canUndo)
                        Button("Redo \(library.redoName ?? "")", systemImage: "arrow.uturn.forward") { library.redo() }
                            .disabled(!library.canRedo)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .photosPicker(isPresented: $showingPhotos, selection: $photoItems, matching: .videos,
                          preferredItemEncoding: .current)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await importFromPhotos(items) }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await importFiles(urls) }
                }
            }
            .alert("New Section", isPresented: $namingSection) {
                TextField("e.g. Kills", text: $newSectionName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let name = newSectionName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { _ = library.addSection(title: name) }
                }
            }
        }
    }

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        importStatus = items.count == 1 ? "Importing a video…" : "Importing \(items.count) videos…"
        let urls = await PickedMovie.load(items)
        _ = await model.library.importFiles(urls)
        PickedMovie.cleanUp(urls)
        importStatus = nil
    }

    private func importFiles(_ urls: [URL]) async {
        importStatus = urls.count == 1 ? "Importing a video…" : "Importing \(urls.count) videos…"
        _ = await model.library.importFiles(urls)
        importStatus = nil
    }
}

struct ClipRow: View {
    let clip: Clip
    let url: URL
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.black
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(clip.isIncluded ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .strikethrough(!clip.isIncluded, color: .secondary)
                HStack(spacing: 6) {
                    Text(clip.durationText)
                    if clip.stars > 0 {
                        Text(String(repeating: "★", count: clip.stars)).foregroundStyle(.yellow)
                    }
                    if clip.spotlight != nil {
                        Image(systemName: "scope").foregroundStyle(.tint)
                    }
                    if !clip.isIncluded {
                        Text("Left out")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task(id: clip.fileName) {
            thumbnail = await ThumbnailLoader.shared.thumbnail(for: url, crop: clip.unitCrop)
        }
    }
}

/// One clip: play it, rename it, rate it, trim it, leave it out of the reel.
struct ClipDetailScreen: View {
    @Environment(IOSModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let clipID: Clip.ID
    @State private var player: AVPlayer?
    @State private var title = ""
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var spotlighting = false

    var body: some View {
        let library = model.library
        if let clip = library.clip(withID: clipID) {
            Form {
                Section {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("Name", text: $title)
                        .onSubmit { library.rename(clip, to: title) }
                    Toggle("In Reel", isOn: Binding(get: { clip.isIncluded },
                                                    set: { library.setIncluded([clip.id], $0) }))
                    LabeledContent("Rating") {
                        HStack(spacing: 4) {
                            ForEach(1...5, id: \.self) { n in
                                Button {
                                    library.setRating(clip.stars == n ? 0 : n, for: [clip.id])
                                } label: {
                                    Image(systemName: n <= clip.stars ? "star.fill" : "star")
                                        .foregroundStyle(n <= clip.stars ? .yellow : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button(clip.spotlight == nil ? "Spotlight the Athlete…" : "Edit Spotlight…", systemImage: "scope") {
                        player?.pause()
                        spotlighting = true
                    }
                }
                Section("Trim") {
                    LabeledContent("Start", value: Clip.format(trimStart))
                    Slider(value: $trimStart, in: 0...max(0.1, clip.duration), onEditingChanged: { editing in
                        if !editing { applyTrim(clip) } else { seek(trimStart) }
                    })
                    .onChange(of: trimStart) { _, v in seek(v) }
                    LabeledContent("End", value: Clip.format(trimEnd))
                    Slider(value: $trimEnd, in: 0...max(0.1, clip.duration), onEditingChanged: { editing in
                        if !editing { applyTrim(clip) } else { seek(trimEnd) }
                    })
                    .onChange(of: trimEnd) { _, v in seek(v) }
                    if clip.isTrimmed {
                        Button("Reset Trim") {
                            library.setTrim(clip, start: nil, end: nil)
                            trimStart = 0
                            trimEnd = clip.duration
                        }
                    }
                }
                Section {
                    LabeledContent("Length", value: clip.durationText)
                    LabeledContent("Size", value: clip.resolutionText)
                    if !clip.playerList.isEmpty {
                        LabeledContent("Players", value: clip.playerList.map { library.playerLabel($0) }.joined(separator: ", "))
                    }
                }
                Section {
                    Button("Delete Clip", role: .destructive) {
                        player?.pause()
                        library.delete(clip)
                        dismiss()
                    }
                }
            }
            .navigationTitle(clip.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                title = clip.title
                trimStart = clip.trimStartSeconds
                trimEnd = clip.trimEndSeconds
                if player == nil {
                    let p = AVPlayer(url: library.url(for: clip))
                    p.seek(to: CMTime(seconds: clip.trimStartSeconds, preferredTimescale: 600))
                    player = p
                }
            }
            .onDisappear {
                player?.pause()
                if title != clip.title, !title.isEmpty { library.rename(clip, to: title) }
            }
            .fullScreenCover(isPresented: $spotlighting) {
                SpotlightScreen(clip: clip, url: library.url(for: clip))
            }
        } else {
            ContentUnavailableView("Clip Deleted", systemImage: "trash")
        }
    }

    private func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func applyTrim(_ clip: Clip) {
        if trimEnd - trimStart < 0.5 { trimEnd = min(clip.duration, trimStart + 0.5) }
        let start = trimStart > 0.05 ? trimStart : nil
        let end = trimEnd < clip.duration - 0.05 ? trimEnd : nil
        model.library.setTrim(clip, start: start, end: end)
    }
}

/// Tap the athlete on the clip's first frame; pinch or use the slider to size the ring.
struct SpotlightScreen: View {
    @Environment(IOSModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let clip: Clip
    let url: URL
    @State private var image: CGImage?
    @State private var spot: Spotlight = .standard

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    let picture = fitted(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .frame(width: picture.width, height: picture.height)
                                .offset(x: picture.minX, y: picture.minY)
                            let c = CGPoint(x: picture.minX + spot.x * picture.width, y: picture.minY + spot.y * picture.height)
                            let r = spot.radius * picture.height
                            let rx = r * model.exporter.options.spotlightShape.aspect
                            Ellipse()
                                .stroke(model.profile.profile.accentColor, lineWidth: 3)
                                .frame(width: rx * 2, height: r * 2)
                                .position(c)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard picture.width > 0 else { return }
                        spot.x = min(1, max(0, (value.location.x - picture.minX) / picture.width))
                        spot.y = min(1, max(0, (value.location.y - picture.minY) / picture.height))
                    })
                }
                HStack {
                    Image(systemName: "circle").font(.caption)
                    Slider(value: $spot.radius, in: 0.04...0.3)
                    Image(systemName: "circle").font(.title3)
                }
                .padding(.horizontal)
                Text("Tap your athlete, then size the ring.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.bottom)
            .navigationTitle("Spotlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.library.setSpotlight(spot, for: clip.id)
                        dismiss()
                    }
                }
                if clip.spotlight != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remove Spotlight", role: .destructive) {
                            model.library.setSpotlight(nil, for: clip.id)
                            dismiss()
                        }
                    }
                }
            }
            .task {
                if let existing = clip.spotlight { spot = existing }
                image = await VideoFrames.firstFrame(url: url, at: clip.trimStartSeconds, crop: clip.unitCrop)
            }
        }
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

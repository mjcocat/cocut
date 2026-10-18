import AppKit
import SwiftUI

struct ClipsView: View {
    @Environment(AppModel.self) private var model

    @State private var selectedID: Clip.ID?
    @State private var deleting: Clip?

    private var library: ClipLibrary { model.library }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasScreenPermission {
                PermissionBanner()
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
            }

            if library.clips.isEmpty {
                emptyState
            } else {
                HSplitView {
                    ClipListPane(selectedID: $selectedID, deleting: $deleting)
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
                    ClipDetailPane(clip: library.clip(withID: selectedID), deleting: $deleting)
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
            if selectedID == nil { selectedID = library.clips.first?.id }
        }
        .onChange(of: library.recentlyAddedID) { _, newID in
            if let newID { selectedID = newID }
        }
        .confirmationDialog(
            "Move “\(deleting?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let clip = deleting else { return }
                if selectedID == clip.id {
                    let index = library.clips.firstIndex(of: clip) ?? 0
                    library.delete(clip)
                    selectedID = library.clips.indices.contains(index) ? library.clips[index].id : library.clips.last?.id
                } else {
                    library.delete(clip)
                }
            }
        } message: {
            Text("You can restore it from the Trash in Finder.")
        }
    }

    private var subtitle: String {
        let count = library.clips.count
        guard count > 0 else { return "" }
        return "\(count) \(count == 1 ? "clip" : "clips") · \(Clip.format(library.totalDuration)) total"
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

            Text("Press ⌥⌘R from any app to start again on the same area, or to finish.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List

private struct ClipListPane: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedID: Clip.ID?
    @Binding var deleting: Clip?

    private var library: ClipLibrary { model.library }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(library.clips) { clip in
                        ClipRow(clip: clip,
                                number: (library.clips.firstIndex(of: clip) ?? 0) + 1,
                                url: library.url(for: clip))
                            .tag(clip.id)
                            .id(clip.id)
                            .contextMenu {
                                Button("Show in Finder") { library.revealInFinder(clip) }
                                Divider()
                                Button("Move to Trash…", role: .destructive) { deleting = clip }
                            }
                    }
                    .onMove { library.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
                .onDeleteCommand {
                    if let clip = library.clip(withID: selectedID) { deleting = clip }
                }
                .onChange(of: library.recentlyAddedID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.snappy) { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text("Drag clips into the order you want in the reel.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

private struct ClipRow: View {
    let clip: Clip
    let number: Int
    let url: URL

    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 3) {
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
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .task(id: url) {
            image = await ThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}

// MARK: - Detail

private struct ClipDetailPane: View {
    @Environment(AppModel.self) private var model
    let clip: Clip?
    @Binding var deleting: Clip?

    @State private var titleDraft = ""
    @State private var trimRequest = 0
    @FocusState private var titleFocused: Bool

    private var library: ClipLibrary { model.library }

    var body: some View {
        if let clip {
            VStack(spacing: 0) {
                PlayerView(
                    url: library.url(for: clip),
                    trimStart: clip.trimStart,
                    trimEnd: clip.trimEnd,
                    isActive: !model.isBusy,
                    trimRequest: trimRequest,
                    onTrimmed: { start, end in library.setTrim(clip, start: start, end: end) }
                )
                // Rebuild the player when the clip or its trim changes.
                .id("\(clip.id)-\(clip.trimStart ?? -1)-\(clip.trimEnd ?? -1)")
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

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

                    Menu {
                        Button("Show in Finder") { library.revealInFinder(clip) }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { deleting = clip }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onAppear { titleDraft = clip.title }
            .onChange(of: clip.id) { _, _ in titleDraft = clip.title }
        } else {
            ContentUnavailableView("Select a Clip", systemImage: "play.rectangle",
                                   description: Text("Choose a clip on the left to watch, rename or trim it."))
        }
    }

    private func details(_ clip: Clip) -> String {
        var parts = [clip.durationText]
        if clip.isTrimmed { parts.append("trimmed from \(Clip.format(clip.duration))") }
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

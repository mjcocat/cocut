import AppKit
import SwiftUI

struct ClipsView: View {
    @Environment(AppModel.self) private var model

    @State private var selectedID: Clip.ID?
    @State private var previewing: Clip?
    @State private var renaming: Clip?
    @State private var renameText = ""
    @State private var deleting: Clip?

    private var library: ClipLibrary { model.library }

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasScreenPermission {
                PermissionBanner()
                    .padding([.horizontal, .top], 20)
            }

            if library.clips.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("Clips")
        .navigationSubtitle(subtitle)
        .overlay(alignment: .bottom) {
            if model.phase == .saving {
                SavingToast()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.phase)
        .sheet(item: $previewing) { clip in
            ClipPreviewView(clip: clip, url: library.url(for: clip))
        }
        .alert("Rename Clip", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let clip = renaming { library.rename(clip, to: renameText) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move “\(deleting?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let clip = deleting {
                    if selectedID == clip.id { selectedID = nil }
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

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(library.clips) { clip in
                        ClipCard(
                            clip: clip,
                            url: library.url(for: clip),
                            isSelected: selectedID == clip.id,
                            isNew: library.recentlyAddedID == clip.id
                        )
                        .id(clip.id)
                        .onTapGesture(count: 2) { previewing = clip }
                        .onTapGesture { selectedID = clip.id }
                        .contextMenu { menu(for: clip) }
                    }
                }
                .padding(24)
            }
            .onChange(of: library.recentlyAddedID) { _, newID in
                guard let newID else { return }
                selectedID = newID
                withAnimation(.snappy) { proxy.scrollTo(newID, anchor: .center) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.001)) // makes empty space clickable
        .onTapGesture { selectedID = nil }
        .onDeleteCommand {
            if let id = selectedID, let clip = library.clips.first(where: { $0.id == id }) {
                deleting = clip
            }
        }
        .onKeyPress(.space) {
            guard let id = selectedID, let clip = library.clips.first(where: { $0.id == id }) else { return .ignored }
            previewing = clip
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func menu(for clip: Clip) -> some View {
        Button("Preview") { previewing = clip }
        Button("Rename…") {
            renameText = clip.title
            renaming = clip
        }
        Divider()
        Button("Show in Finder") { library.revealInFinder(clip) }
        Divider()
        Button("Move to Trash…", role: .destructive) { deleting = clip }
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
            Text("Open game film on YouTube or Hudl, then record just the part of the screen showing the video. Each recording becomes a clip here.")
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

            Text("Tip: press ⌥⌘R from any app to record the same area again, and ⌥⌘R again to stop. Controls also live in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Clip card

struct ClipCard: View {
    let clip: Clip
    let url: URL
    let isSelected: Bool
    let isNew: Bool

    @State private var image: CGImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(clip.title)
                        .font(.headline)
                        .lineLimit(1)
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                Text("\(clip.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(clip.resolutionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .task(id: url) {
            image = await ThumbnailLoader.shared.thumbnail(for: url)
        }
    }

    private var thumbnail: some View {
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .overlay {
                if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .glassEffect(.regular, in: Circle())
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(clip.durationText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: isSelected ? 3 : 1)
            }
            .shadow(color: .black.opacity(isHovering ? 0.22 : 0.1), radius: isHovering ? 12 : 5, y: isHovering ? 6 : 2)
            .scaleEffect(isHovering ? 1.015 : 1)
            .animation(.snappy(duration: 0.18), value: isHovering)
            .animation(.snappy(duration: 0.18), value: isSelected)
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
                Text("Turn on Cocut in System Settings › Privacy & Security › Screen & System Audio Recording. You may need to quit and reopen the app afterward.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Settings") { model.requestPermission() }
                .controlSize(.large)
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

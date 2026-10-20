import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case clips, playerCard, export
}

/// The main window shows one sheet at a time; the Setup Guide goes first, then any update offer.
private enum MainSheet: String, Identifiable {
    case setup, update
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .clips

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
            ProjectSwitcher()
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            List(selection: $selection) {
                Section("Highlight Reel") {
                    Label("Clips", systemImage: "film.stack")
                        .badge(model.library.clips.count)
                        .tag(SidebarItem.clips)
                    Label("Player Card", systemImage: "person.text.rectangle")
                        .tag(SidebarItem.playerCard)
                    Label("Export", systemImage: "square.and.arrow.up")
                        .badge(model.exporter.isRunning ? Text("…") : nil)
                        .tag(SidebarItem.export)
                }
            }
            ReelSummary(onExport: { selection = .export })
                .padding(Design.Space.s + 2)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 280)
        } detail: {
            Group {
                switch selection ?? .clips {
                case .clips:
                    ClipsView()
                case .playerCard:
                    PlayerCardEditor()
                case .export:
                    ExportView()
                }
            }
            // Fresh screens (selection, scroll position) for each project.
            .id(model.projects.currentID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let release = model.updater.availableRelease, !model.updater.isPresentingSheet {
                    Button {
                        model.updater.showOffer()
                    } label: {
                        Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.green)
                    .help("Cocut \(release.version) is available. Click to see what's new and install it.")
                }
            }

            // The ways film gets in, then watching the result. Undo and Redo live in the Edit menu
            // (⌘Z, ⇧⌘Z), like every Mac app.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.importVideosWithPanel() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Add video files, such as Hudl downloads or phone videos (⌘I)")
                .disabled(model.isBusy)

                Button {
                    openWindow(id: "rallies")
                } label: {
                    Label("Find Rallies", systemImage: "figure.volleyball")
                        .labelStyle(.titleAndIcon)
                }
                .help("Find the rallies in a full match video and skip the dead time (⇧⌘M)")

                Button {
                    openWindow(id: "preview")
                } label: {
                    Label("Preview Reel", systemImage: "play.rectangle")
                }
                .help("Play the whole reel as it will export, without rendering it (⌘Y)")
                .disabled(model.library.includedClips.isEmpty)
            }

            // Record is a plain button (the toolbar keeps a button's red, not a menu's), with the
            // other ways to record in the menu beside it.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.recordNewRegion() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(Design.record)
                .help("Drag over the video on screen, then press play to record (⇧⌘R)")
                .disabled(model.isBusy)

                Menu {
                    Button("Record Full Screen   ⇧⌘F") { Task { await model.recordFullScreen() } }
                    Button("Record Same Region Again   ⇧⌘L") { Task { await model.recordLastRegion() } }
                        .disabled(!model.canRecordLastRegion)
                } label: {
                    Label("More Ways to Record", systemImage: "chevron.down")
                }
                .menuIndicator(.hidden)
                .help("Record the full screen, or the last region again")
                .disabled(model.isBusy)
            }
        }
        // One sheet modifier for both: two .sheet modifiers on the same view means only one of
        // them can ever present, which hid the update offer.
        .sheet(item: Binding<MainSheet?>(
            get: {
                if model.showingSetupGuide { return .setup }
                if model.updater.isPresentingSheet { return .update }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if model.showingSetupGuide {
                    model.showingSetupGuide = false
                } else if model.updater.isPresentingSheet {
                    model.updater.dismiss()
                }
            }
        )) { sheet in
            switch sheet {
            case .setup:
                SetupGuideView()
                    .environment(model)
            case .update:
                UpdateView(updater: model.updater)
                    .interactiveDismissDisabled()
            }
        }
        .onAppear {
            // First launch: walk through the one-time setup.
            if !model.settings.hasCompletedSetup || !model.hasScreenPermission {
                model.showingSetupGuide = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
        }
        .onChange(of: model.requestedSection) { _, section in
            guard let section else { return }
            selection = section
            model.requestedSection = nil
        }
    }
}

/// The foot of the sidebar: the reel at a glance (clips in it, about how long it runs), with
/// Preview and Export a click away from any screen.
private struct ReelSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let onExport: () -> Void

    var body: some View {
        let clips = model.library.includedClips
        VStack(alignment: .leading, spacing: Design.Space.xs + 2) {
            SectionLabel("Your Reel")
            if clips.isEmpty {
                Text("No clips yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let seconds = model.exporter.estimatedDuration(plan: model.library.reelPlan, profile: model.profile.profile)
                Text("\(clips.count) \(clips.count == 1 ? "clip" : "clips") · \(Clip.format(seconds))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            HStack(spacing: Design.Space.s) {
                Button {
                    openWindow(id: "preview")
                } label: {
                    Label("Preview", systemImage: "play.fill")
                }
                .help("Play the whole reel as it will export (⌘Y)")
                Button("Export…", action: onExport)
                    .help("Choose cards, transitions and size, then export (⌘E)")
            }
            .controlSize(.small)
            .disabled(clips.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Design.Space.m - 2, radius: Design.Radius.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your reel")
    }
}

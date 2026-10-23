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

            // Every way film gets in, in one menu (the same four as Get Started). Recording is also
            // in the menu bar, Find Rallies in the Window menu (⇧⌘M) and Preview in Export (⌘Y).
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Menu {
                        Button {
                            startFilm(.fullMatch, model: model, openWindow: openWindow)
                        } label: {
                            Label("From Your Mac…", systemImage: "internaldrive")
                        }
                        Button {
                            startFilm(.youtube, model: model, openWindow: openWindow)
                        } label: {
                            Label("From YouTube or Hudl…", systemImage: FilmSource.youtube.icon)
                        }
                        Divider()
                        Button {
                            openWindow(id: "rallies")
                        } label: {
                            Label("Matches You've Analyzed…   ⇧⌘M", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Label("Full Match", systemImage: FilmSource.fullMatch.icon)
                    }
                    Button {
                        startFilm(.clips, model: model, openWindow: openWindow)
                    } label: {
                        Label("Clips on Your Mac…", systemImage: FilmSource.clips.icon)
                    }
                    .disabled(model.isBusy)
                    Menu {
                        Button {
                            Task { await model.recordNewRegion() }
                        } label: {
                            Label("Drag Over a Region   ⇧⌘R", systemImage: "rectangle.dashed")
                        }
                        Button {
                            Task { await model.recordFullScreen() }
                        } label: {
                            Label("Full Screen   ⇧⌘F", systemImage: "rectangle.dashed.badge.record")
                        }
                        Button {
                            Task { await model.recordLastRegion() }
                        } label: {
                            Label("Same Region Again   ⇧⌘L", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(!model.canRecordLastRegion)
                    } label: {
                        Label("Record Your Screen", systemImage: FilmSource.online.icon)
                    }
                    .disabled(model.isBusy)
                    Divider()
                    Button {
                        model.showingAddFromProjects = true
                    } label: {
                        Label("From Other Projects…", systemImage: "square.stack.3d.up")
                    }
                } label: {
                    Label("Add Videos", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help("Add film: a full match, a YouTube or Hudl video, clips on your Mac, a screen recording, or clips from other projects")
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

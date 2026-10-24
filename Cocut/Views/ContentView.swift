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

            // Every way film gets in, in one menu (the same four as Get Started): a full match goes
            // to Find Rallies, clips straight into Clips. Recording is also
            // in the menu bar, Find Rallies in the Window menu (⇧⌘M) and Preview in Export (⌘Y).
            ToolbarItemGroup(placement: .primaryAction) {
                // A button rather than a SwiftUI Menu: the toolbar draws menus grey whatever their
                // style, and this is the window's main action, so it's filled in the Cocut blue.
                // Clicking it opens the menu (`showAddMenu`).
                Button {
                    showAddMenu()
                } label: {
                    Label("Add Videos", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
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

    /// The Add Videos menu, under the pointer: the same four ways in as Get Started, plus clips
    /// from other projects.
    private func showAddMenu() {
        let menu = ActionMenu()
        let match = menu.submenu("Full Match", icon: FilmSource.fullMatch.icon)
        menu.item("From Your Mac…", icon: "internaldrive", in: match) { startFilm(.fullMatch, model: model, openWindow: openWindow) }
        menu.item("From YouTube or Hudl…", icon: FilmSource.youtube.icon, in: match) {
            model.importKind = .match
            openWindow(id: "youtube")
        }
        match.addItem(.separator())
        menu.item("Matches You've Analyzed…   ⇧⌘M", icon: "clock.arrow.circlepath", in: match) { openWindow(id: "rallies") }

        let clips = menu.submenu("Clips Only", icon: FilmSource.clips.icon)
        menu.item("From Your Mac…", icon: "internaldrive", enabled: !model.isBusy, in: clips) {
            startFilm(.clips, model: model, openWindow: openWindow)
        }
        menu.item("From YouTube or Hudl…", icon: FilmSource.youtube.icon, in: clips) {
            model.importKind = .clip
            openWindow(id: "youtube")
        }

        let record = menu.submenu("Record Your Screen", icon: FilmSource.online.icon, enabled: !model.isBusy)
        menu.item("Drag Over a Region   ⇧⌘R", icon: "rectangle.dashed", in: record) { Task { await model.recordNewRegion() } }
        menu.item("Full Screen   ⇧⌘F", icon: "rectangle.dashed.badge.record", in: record) { Task { await model.recordFullScreen() } }
        menu.item("Same Region Again   ⇧⌘L", icon: "arrow.clockwise.circle", enabled: model.canRecordLastRegion, in: record) {
            Task { await model.recordLastRegion() }
        }

        menu.menu.addItem(.separator())
        menu.item("From Other Projects…", icon: "square.stack.3d.up") { model.showingAddFromProjects = true }
        menu.popUp()
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

/// An AppKit menu whose items run closures, for a menu opened from a button (`showAddMenu`).
@MainActor
final class ActionMenu: NSObject {
    let menu = NSMenu()
    private var actions: [() -> Void] = []
    /// The menu being shown: kept alive until it closes (its items only hold it weakly).
    private static var shown: ActionMenu?

    override init() {
        super.init()
        menu.autoenablesItems = false
    }

    func item(_ title: String, icon: String, enabled: Bool = true, in parent: NSMenu? = nil, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        actions.append(action)
        (parent ?? menu).addItem(item)
    }

    func submenu(_ title: String, icon: String, enabled: Bool = true) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        item.isEnabled = enabled
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        item.submenu = sub
        menu.addItem(item)
        return sub
    }

    /// Opens just under the toolbar button that was clicked (or at the pointer).
    func popUp() {
        Self.shown = self
        defer { Self.shown = nil }
        // The toolbar isn't in the window's content view but beside it, in the window's frame view.
        if let event = NSApp.currentEvent, let frameView = event.window?.contentView?.superview {
            let click = frameView.convert(event.locationInWindow, from: nil)
            if let hit = frameView.hitTest(click),
               let control = sequence(first: hit, next: { $0.superview }).first(where: { $0 is NSControl }) {
                let frame = control.convert(control.bounds, to: frameView)
                let below = NSPoint(x: frame.minX, y: frameView.isFlipped ? frame.maxY + 4 : frame.minY - 4)
                menu.popUp(positioning: nil, at: below, in: frameView)
            } else {
                menu.popUp(positioning: nil, at: click, in: frameView)
            }
            return
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        // After the menu has closed, so windows and sheets it opens come up normally.
        DispatchQueue.main.async { action() }
    }
}

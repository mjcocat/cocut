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
            .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 280)
        } detail: {
            switch selection ?? .clips {
            case .clips:
                ClipsView()
            case .playerCard:
                PlayerCardEditor()
            case .export:
                ExportView()
            }
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

                Button {
                    openWindow(id: "preview")
                } label: {
                    Label("Preview Reel", systemImage: "play.rectangle")
                }
                .help("Play the whole reel as it will export, without rendering it (⌘Y)")
                .disabled(model.library.includedClips.isEmpty)

                Button {
                    Task { await model.recordLastRegion() }
                } label: {
                    Label("Record Same Region", systemImage: "arrow.counterclockwise")
                }
                .help("Record the last region again (⇧⌘L)")
                .disabled(!model.canRecordLastRegion)

                Button {
                    Task { await model.recordNewRegion() }
                } label: {
                    Label("Record Region", systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Select part of the screen and record it (⇧⌘R)")
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

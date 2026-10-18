import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case clips, playerCard, export
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
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
        .sheet(isPresented: Binding(
            get: { model.updater.isPresentingSheet },
            set: { if !$0 { model.updater.dismiss() } }
        )) {
            UpdateView(updater: model.updater)
                .interactiveDismissDisabled()
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

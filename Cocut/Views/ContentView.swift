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
                        .tag(SidebarItem.export)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 280)
        } detail: {
            switch selection ?? .clips {
            case .clips:
                ClipsView()
            case .playerCard:
                ComingSoonView(
                    title: "Player Card",
                    systemImage: "person.text.rectangle",
                    message: "Add a headshot, name, grad year, height, club and jersey number for the reel's intro."
                )
                .navigationTitle("Player Card")
            case .export:
                ComingSoonView(
                    title: "Export",
                    systemImage: "square.and.arrow.up",
                    message: "Stitch the intro card and your clips into one 1080p video, ready to send to coaches."
                )
                .navigationTitle("Export")
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
    }
}

struct ComingSoonView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Text("Coming in the next build")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
        }
    }
}

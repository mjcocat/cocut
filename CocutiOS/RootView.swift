import SwiftUI

/// Tabs on iPhone; a sidebar on iPad.
struct RootView: View {
    @Environment(IOSModel.self) private var model
    @State private var tab: Pane = .clips

    enum Pane: Hashable { case clips, rallies, card, export }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Clips", systemImage: "film.stack", value: Pane.clips) {
                ClipsScreen()
            }
            Tab("Find Rallies", systemImage: "volleyball", value: Pane.rallies) {
                RalliesScreen(onAddedToClips: { tab = .clips })
            }
            Tab("Player Card", systemImage: "person.crop.rectangle", value: Pane.card) {
                PlayerCardScreen()
            }
            Tab("Export", systemImage: "square.and.arrow.up", value: Pane.export) {
                ExportScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(notice)
            }
        }
        .animation(.spring(duration: 0.35), value: model.notice)
    }
}

/// Switch, create and see the project's name; shown in each screen's toolbar.
struct ProjectMenu: View {
    @Environment(IOSModel.self) private var model
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Menu {
            Section("Projects") {
                ForEach(model.projects.projects) { project in
                    Button {
                        model.openProject(project.id)
                    } label: {
                        if project.id == model.projects.currentID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            }
            Button("New Project…", systemImage: "plus") {
                newName = ""
                naming = true
            }
        } label: {
            Label(model.projects.current.name, systemImage: "folder")
        }
        .alert("New Project", isPresented: $naming) {
            TextField("Name, e.g. Fall 2026 Club", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.newProject(named: name) }
            }
        }
    }
}

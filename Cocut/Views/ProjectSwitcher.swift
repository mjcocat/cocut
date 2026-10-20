import SwiftUI

/// The project menu at the top of the sidebar: switch, create, rename, delete.
struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var creating = false
    @State private var renaming = false
    @State private var deleting: Project?
    @State private var name = ""
    @State private var copyCard = true

    private var projects: ProjectStore { model.projects }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PROJECTS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(projects.projects) { project in
                let isCurrent = project.id == projects.currentID
                Button {
                    model.openProject(project.id)
                    showingList = false
                } label: {
                    HStack {
                        Image(systemName: isCurrent ? "checkmark" : "folder")
                            .frame(width: 16)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        Text(project.name).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy || model.exporter.isRunning)
            }
            Divider().padding(.vertical, 6)
            listAction("New Project…", "plus") {
                name = ""
                copyCard = true
                creating = true
            }
            listAction("Rename “\(projects.current.name)”…", "pencil") {
                name = projects.current.name
                renaming = true
            }
            listAction("Show in Finder", "folder") { projects.revealInFinder(projects.current) }
            listAction("Delete “\(projects.current.name)”…", "trash", destructive: true) {
                deleting = projects.current
            }
            .disabled(model.isBusy)
        }
        .padding(10)
        .frame(width: 280)
    }

    private func listAction(_ title: String, _ icon: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button {
            showingList = false
            action()
        } label: {
            HStack {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @State private var showingList = false

    var body: some View {
        // A plain button + popover: a macOS menu button can only show an icon and one line of
        // text, which hid the project's name.
        Button {
            showingList.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PROJECT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(projects.current.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingList, arrowEdge: .bottom) {
            projectList
        }
        .help("Each project has its own clips and Player Card, like “Fall 2026 Club” and “HS Season”")
        .sheet(isPresented: $creating) {
            NewProjectWizard { name, copyCard, athlete, source in
                model.createProject(name: name, copyCard: copyCard, athlete: athlete)
                if let source { startFilm(source, model: model, openWindow: openWindow) }
            }
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { projects.rename(projects.currentID, to: name) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Move “\(deleting?.name ?? "")” to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let deleting { model.deleteProject(deleting.id) }
            }
        } message: {
            Text(projects.projects.count == 1
                 ? "Its clips and Player Card go to the Trash too, and Cocut starts over with an empty project. You can put them back from the Trash in Finder."
                 : "Its clips and Player Card go to the Trash too. You can put them back from the Trash in Finder.")
        }
    }
}


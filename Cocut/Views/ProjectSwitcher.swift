import SwiftUI

/// The project menu at the top of the sidebar: switch, create, rename, delete.
struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var renaming = false
    @State private var deleting: Project?
    @State private var name = ""
    @State private var copyCard = true

    private var projects: ProjectStore { model.projects }

    var body: some View {
        Menu {
            Section("Projects") {
                ForEach(projects.projects) { project in
                    Button {
                        model.openProject(project.id)
                    } label: {
                        if project.id == projects.currentID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                    .disabled(model.isBusy || model.exporter.isRunning)
                }
            }
            Divider()
            Button("New Project…") {
                name = ""
                copyCard = true
                creating = true
            }
            Button("Rename “\(projects.current.name)”…") {
                name = projects.current.name
                renaming = true
            }
            Button("Show in Finder") { projects.revealInFinder(projects.current) }
            Divider()
            Button("Delete “\(projects.current.name)”…", role: .destructive) {
                deleting = projects.current
            }
            .disabled(projects.projects.count < 2 || model.isBusy)
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
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Each project has its own clips and Player Card, like “Fall 2026 Club” and “HS Season”")
        .sheet(isPresented: $creating) {
            NewProjectSheet(name: $name, copyCard: $copyCard) {
                model.createProject(name: name, copyCard: copyCard)
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
            Text("Its clips and Player Card go to the Trash too. You can put them back from the Trash in Finder.")
        }
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    @Binding var copyCard: Bool
    let create: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.title2.weight(.semibold))
            Text("A project has its own clips, sections, tags and Player Card. Use one per season, team or athlete.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("Fall 2026 Club"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(done)
            Toggle("Start with a copy of this project’s Player Card", isOn: $copyCard)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func done() {
        create()
        dismiss()
    }
}

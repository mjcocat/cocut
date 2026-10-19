import Foundation

/// A reel project: its own clips, sections, tags, roster and Player Card, in its own folder.
struct Project: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// Folder name inside ~/Movies/Cocut/Projects.
    var folder: String
    var createdAt: Date
}

/// Keeps the list of projects in ~/Movies/Cocut/projects.json and which one is open.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var currentID: UUID

    let rootDirectory: URL
    private var projectsDirectory: URL { rootDirectory.appending(path: "Projects", directoryHint: .isDirectory) }
    private var indexURL: URL { rootDirectory.appending(path: "projects.json") }
    private static let currentKey = "currentProjectID"

    var current: Project { projects.first { $0.id == currentID } ?? projects[0] }

    init() {
        let fm = FileManager.default
        let movies = Platform.moviesRoot
        rootDirectory = movies.appending(path: "Cocut", directoryHint: .isDirectory)

        // Carry everything over from the app's previous name.
        let legacy = movies.appending(path: "Highlight Creator", directoryHint: .isDirectory)
        if fm.fileExists(atPath: legacy.path(percentEncoded: false)),
           !fm.fileExists(atPath: rootDirectory.path(percentEncoded: false)) {
            try? fm.moveItem(at: legacy, to: rootDirectory)
            Log.info("Moved clip library from \(legacy.path(percentEncoded: false))")
        }
        try? fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        currentID = UUID()
        if let data = try? Data(contentsOf: indexURL),
           let list = try? Self.decoder.decode([Project].self, from: data), !list.isEmpty {
            projects = list
        } else {
            projects = [migrateOrCreateFirst()]
            save()
        }
        let saved = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init)
        currentID = projects.first { $0.id == saved }?.id ?? projects[0].id
        try? fm.createDirectory(at: directory(for: current), withIntermediateDirectories: true)
    }

    func directory(for project: Project) -> URL {
        projectsDirectory.appending(path: project.folder, directoryHint: .isDirectory)
    }

    /// Before projects existed, the one library lived directly in ~/Movies/Cocut. Move it into
    /// the first project (a rename on the same disk: instant, nothing is copied).
    private func migrateOrCreateFirst() -> Project {
        let fm = FileManager.default
        var name = "My Reel"
        let oldProfile = rootDirectory.appending(path: "profile.json")
        if let data = try? Data(contentsOf: oldProfile),
           let profile = try? JSONDecoder().decode(PlayerProfile.self, from: data), !profile.firstName.isEmpty {
            name = "\(profile.firstName)’s Reel"
        }
        let project = Project(id: UUID(), name: name, folder: UUID().uuidString, createdAt: .now)
        let dir = directory(for: project)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var moved: [String] = []
        for item in ["Clips", "library.json", "profile.json", "headshot.png"] {
            let from = rootDirectory.appending(path: item)
            guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            do {
                try fm.moveItem(at: from, to: dir.appending(path: item))
                moved.append(item)
            } catch {
                Log.error("Couldn't move \(item) into the first project: \(error.localizedDescription)")
            }
        }
        if !moved.isEmpty { Log.info("Moved the existing library into project “\(name)”: \(moved.joined(separator: ", "))") }
        return project
    }

    // MARK: Changes

    func select(_ id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        currentID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentKey)
    }

    /// Creates a project, optionally starting with a copy of another project's Player Card.
    @discardableResult
    func create(name: String, copyingCardFrom source: Project?) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(id: UUID(), name: trimmed.isEmpty ? "New Reel" : trimmed,
                              folder: UUID().uuidString, createdAt: .now)
        let dir = directory(for: project)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appending(path: "Clips"), withIntermediateDirectories: true)
        if let source {
            let from = directory(for: source)
            for item in ["profile.json", "headshot.png"] {
                try? fm.copyItem(at: from.appending(path: item), to: dir.appending(path: item))
            }
        }
        projects.append(project)
        save()
        Log.info("Created project “\(project.name)”")
        return project
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = trimmed
        save()
    }

    /// Moves a project's folder to the Trash. The last project can't be deleted.
    func delete(_ id: UUID) throws {
        guard projects.count > 1, let project = projects.first(where: { $0.id == id }) else { return }
        let dir = directory(for: project)
        if FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
            try Platform.moveToTrash(dir)
        }
        projects.removeAll { $0.id == id }
        if currentID == id { select(projects[0].id) }
        save()
        Log.info("Moved project “\(project.name)” to the Trash")
    }

    func revealInFinder(_ project: Project) {
        Platform.reveal([directory(for: project)])
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(projects) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

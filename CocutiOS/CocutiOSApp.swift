import SwiftUI

@main
struct CocutiOSApp: App {
    @State private var model = IOSModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// The iPhone/iPad app's state: the open project and the shared engine (library, Player Card,
/// Find Rallies, reel export). The Mac's AppModel adds screen recording on top of the same pieces.
@MainActor
@Observable
final class IOSModel {
    let projects: ProjectStore
    private(set) var library: ClipLibrary
    private(set) var profile: ProfileStore
    let exporter = ReelExporter()
    let preview = ReelPreview()
    let rallies = RallyFinder()

    init() {
        let projects = ProjectStore()
        self.projects = projects
        let dir = projects.directory(for: projects.current)
        library = ClipLibrary(directory: dir)
        profile = ProfileStore(directory: dir)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info("Cocut for iOS \(version) launched")
        rallies.roster = { [weak self] in Set(self?.library.roster.map(\.number) ?? []) }
    }

    func openProject(_ id: UUID) {
        guard id != projects.currentID else { return }
        projects.select(id)
        let dir = projects.directory(for: projects.current)
        library = ClipLibrary(directory: dir)
        profile = ProfileStore(directory: dir)
        exporter.reset()
    }

    func newProject(named name: String) {
        let project = projects.create(name: name, copyingCardFrom: projects.current)
        openProject(project.id)
    }
}

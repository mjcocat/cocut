import AppKit
import SwiftUI

/// Finds the big files Cocut made that it no longer needs (match videos downloaded from YouTube
/// or Hudl, exported reels, temporary files left behind) and moves the chosen ones to the Trash.
/// Clips in projects are never listed: each rally added to Clips is its own file, so a match
/// video isn't needed for them, only for going back to the match in Find Rallies.
@MainActor
@Observable
final class SpaceCleaner {
    enum Kind: Int, CaseIterable {
        case download, export, temporary

        var title: String {
            switch self {
            case .download: return "Downloaded match videos"
            case .export: return "Exported reels"
            case .temporary: return "Temporary files"
            }
        }

        var detail: String {
            switch self {
            case .download: return "Full matches from YouTube and Hudl, in Movies › Cocut › Downloads. Once a match's rallies are in Clips, the video is only needed to go back to the match in Find Rallies."
            case .export: return "Reels you exported, in Movies › Cocut › Exports. Keep the ones you haven't posted or saved elsewhere."
            case .temporary: return "Left behind by downloads or exports that were stopped partway."
            }
        }
    }

    struct Item: Identifiable, Sendable {
        var id: URL { url }
        var url: URL
        var kind: Kind
        var name: String
        var bytes: Int64
        var date: Date?
        /// What it's used for ("Match in Future · 24 rallies in Clips").
        var note: String
        /// Ticked to start with: nothing is lost by deleting it.
        var safe: Bool
        /// Open in Find Rallies right now, so it can't be deleted.
        var inUse = false
    }

    /// A project's folder and name, for matching downloads to the matches analyzed from them.
    struct ProjectFolder: Sendable {
        var name: String
        var folder: URL
    }

    private(set) var items: [Item] = []
    var selected: Set<URL> = []
    private(set) var scanning = false
    /// After moving to the Trash: how much was freed, and what couldn't be moved.
    private(set) var freed: Int64?
    private(set) var failures: [String] = []

    var selectedBytes: Int64 { items.filter { selected.contains($0.url) }.map(\.bytes).reduce(0, +) }

    nonisolated static var downloadsFolder: URL { YouTubeImporter.downloadsFolder }
    nonisolated static var exportsFolder: URL { Platform.moviesRoot.appending(path: "Cocut/Exports", directoryHint: .isDirectory) }

    func scan(projects: [ProjectFolder], openMatch: URL?) async {
        scanning = true
        let found = await Task.detached(priority: .userInitiated) {
            Self.find(projects: projects, openMatch: openMatch)
        }.value
        items = found
        selected = Set(found.filter { $0.safe && !$0.inUse }.map(\.url))
        scanning = false
    }

    /// Moves the ticked files to the Trash (they can still be put back from there).
    func moveSelectedToTrash() {
        var total: Int64 = 0
        failures = []
        for item in items where selected.contains(item.url) && !item.inUse {
            do {
                try Platform.moveToTrash(item.url)
                total += item.bytes
            } catch {
                failures.append(item.name)
                Log.error("Free Up Space: couldn't move \(item.url.path(percentEncoded: false)) to the Trash: \(error.localizedDescription)")
            }
        }
        Log.info("Free Up Space: moved \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) to the Trash")
        items.removeAll { selected.contains($0.url) && !failures.contains($0.name) }
        selected = []
        freed = total
    }

    // MARK: Finding

    private nonisolated static func find(projects: [ProjectFolder], openMatch: URL?) -> [Item] {
        var items: [Item] = []
        let fm = FileManager.default

        // Which project matches came from which video, and how many of their rallies are in Clips.
        var uses: [String: [(project: String, rallies: Int, inClips: Int)]] = [:]
        for project in projects {
            let clipFiles = (try? LibraryFile.clips(project.folder))?.map(\.fileName) ?? []
            for match in MatchStore.recent(project: project.folder) {
                let name = match.sourceURL.deletingPathExtension().lastPathComponent
                let inClips = clipFiles.filter { $0.hasPrefix("\(name) – Rally ") }.count
                uses[match.sourceURL.standardizedFileURL.path(percentEncoded: false), default: []]
                    .append((project.name, match.rallyCount, inClips))
            }
        }

        for url in files(in: downloadsFolder) {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let matches = uses[path] ?? []
            let note: String
            let safe: Bool
            if matches.isEmpty {
                note = "Not analyzed in any project"
                safe = false
            } else {
                note = matches.map { m in
                    "Match in \(m.project) · " + (m.inClips > 0 ? "\(m.inClips) rall\(m.inClips == 1 ? "y" : "ies") in Clips"
                                                              : "no rallies added to Clips yet")
                }.joined(separator: "; ")
                safe = matches.allSatisfy { $0.inClips > 0 }
            }
            let open = openMatch.map { $0.standardizedFileURL.path(percentEncoded: false) == path } ?? false
            items.append(item(url, kind: .download, note: open ? "Open in Find Rallies" : note, safe: safe, inUse: open))
        }

        for url in files(in: exportsFolder) {
            items.append(item(url, kind: .export, note: "Exported reel", safe: false))
        }

        // Work folders of downloads, exports and previews: removed when they finish, but not when
        // Cocut was quit or crashed partway. Only ones older than a day, so none still in use.
        let temporary = fm.temporaryDirectory
        let prefixes = ["cocut-download-", "CocutExport-", "CocutPreview-", "CocutUpdate-"]
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        for url in (try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let date, date < dayAgo else { continue }
            items.append(item(url, kind: .temporary, note: "Left from an unfinished job", safe: true))
        }
        return items.sorted { ($0.kind.rawValue, -$0.bytes) < ($1.kind.rawValue, -$1.bytes) }
    }

    private nonisolated static func files(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isRegularFile == true }
    }

    private nonisolated static func item(_ url: URL, kind: Kind, note: String, safe: Bool, inUse: Bool = false) -> Item {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return Item(url: url, kind: kind, name: url.lastPathComponent, bytes: size(of: url),
                    date: values?.contentModificationDate, note: note, safe: safe, inUse: inUse)
    }

    /// Space a file or folder takes on disk.
    private nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        func one(_ u: URL) -> Int64 {
            let v = try? u.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard (try? url.resourceValues(forKeys: keys))?.isDirectory == true else { return one(url) }
        var total: Int64 = 0
        if let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let u as URL in walk { total += one(u) }
        }
        return total
    }
}

/// A project's clips as saved in its library.json (read without opening the project).
enum LibraryFile {
    static func clips(_ folder: URL) throws -> [Clip] {
        struct File: Decodable { var items: [LibraryItem] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: folder.appending(path: "library.json"))
        if let file = try? decoder.decode(File.self, from: data) { return file.items.compactMap(\.clip) }
        return try decoder.decode([Clip].self, from: data)
    }
}

// MARK: - Window

struct FreeUpSpaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var cleaner = SpaceCleaner()
    @State private var confirming = false

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Design.Space.m) {
                Image(systemName: "externaldrive.badge.minus")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("Free Up Space").font(.title2.weight(.semibold))
                    Text("Big files Cocut made that it may not need any more. Your clips and projects aren't touched. Files go to the Trash, so you can still put them back until you empty it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Space.xl)

            if let freed = cleaner.freed {
                Banner(tone: cleaner.failures.isEmpty ? .success : .warning,
                       icon: cleaner.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                       title: "Moved \(Self.bytes(freed)) to the Trash",
                       message: cleaner.failures.isEmpty
                           ? "Empty the Trash in Finder to get the space back."
                           : "Couldn't move: \(cleaner.failures.joined(separator: ", ")). See the log for why.")
                .padding(.horizontal, Design.Space.xl)
                .padding(.bottom, Design.Space.m)
            }

            Divider()
            list
            Divider()

            HStack {
                Text(cleaner.selected.isEmpty ? "Nothing selected" : "\(cleaner.selected.count) selected · \(Self.bytes(cleaner.selectedBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Done") { dismissWindow(id: "cleanup") }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaner.selected.isEmpty)
            }
            .padding(Design.Space.l)
        }
        .frame(minWidth: 680, minHeight: 520)
        .task { await rescan() }
        .confirmationDialog("Move \(cleaner.selected.count) item\(cleaner.selected.count == 1 ? "" : "s") (\(Self.bytes(cleaner.selectedBytes))) to the Trash?",
                            isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { cleaner.moveSelectedToTrash() }
        } message: {
            Text("A match whose video is deleted can't be opened in Find Rallies again; its clips stay as they are.")
        }
    }

    @ViewBuilder private var list: some View {
        if cleaner.scanning && cleaner.items.isEmpty {
            HStack(spacing: Design.Space.s) {
                ProgressView().controlSize(.small)
                Text("Looking for files…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cleaner.items.isEmpty {
            ContentUnavailableView("Nothing to clean up", systemImage: "checkmark.circle",
                                   description: Text("Cocut has no downloads, exports or leftover files taking up space."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(SpaceCleaner.Kind.allCases, id: \.self) { kind in
                    let group = cleaner.items.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { row($0) }
                        } header: {
                            header(kind, group)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func header(_ kind: SpaceCleaner.Kind, _ group: [SpaceCleaner.Item]) -> some View {
        let usable = group.filter { !$0.inUse }.map(\.url)
        let all = !usable.isEmpty && usable.allSatisfy { cleaner.selected.contains($0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(kind.title).font(.headline)
                Text(Self.bytes(group.map(\.bytes).reduce(0, +))).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(all ? "Select None" : "Select All") {
                    if all { cleaner.selected.subtract(usable) } else { cleaner.selected.formUnion(usable) }
                }
                .buttonStyle(.link)
                .disabled(usable.isEmpty)
            }
            Text(kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func row(_ item: SpaceCleaner.Item) -> some View {
        let isOn = Binding(get: { cleaner.selected.contains(item.url) },
                           set: { if $0 { cleaner.selected.insert(item.url) } else { cleaner.selected.remove(item.url) } })
        return HStack(spacing: Design.Space.m) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .disabled(item.inUse)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text([item.date.map { $0.formatted(date: .abbreviated, time: .omitted) }, item.note]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(item.safe || item.kind != .download ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer()
            Text(Self.bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button {
                Platform.reveal([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    private func rescan() async {
        let folders = model.projects.projects.map {
            SpaceCleaner.ProjectFolder(name: $0.name, folder: model.projects.directory(for: $0))
        }
        await cleaner.scan(projects: folders, openMatch: model.rallies.sourceURL)
    }
}

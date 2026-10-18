import AppKit
import Foundation

/// Checks GitHub Releases for a newer Cocut, downloads it, swaps it into place and relaunches.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let name: String
        let notes: String
        let downloadURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case failed(String)
    }

    static let repo = "mjcocat/cocut"
    static let assetName = "Cocut.zip"

    private(set) var state: State = .idle
    /// Set when the user (not the background check) asked, so the window can show the result.
    var isPresentingSheet = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableRelease: Release? {
        switch state {
        case .available(let r), .downloading(let r), .installing(let r): return r
        default: return nil
        }
    }

    private enum Keys {
        static let lastCheck = "updaterLastCheck"
        static let skipped = "updaterSkippedVersion"
    }

    // MARK: Checking

    /// Called at launch; checks at most once a day and only surfaces a sheet if there's an update.
    func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 24 else { return }
        Task {
            await check(userInitiated: false)
        }
    }

    func checkNow() {
        isPresentingSheet = true
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        if case .checking = state { return }
        if case .downloading = state { return }
        state = .checking
        UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)

        do {
            let release = try await fetchLatestRelease()
            if Self.isVersion(release.version, newerThan: currentVersion) {
                let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
                if !userInitiated, skipped == release.version {
                    state = .idle
                    return
                }
                state = .available(release)
                isPresentingSheet = true
                Log.info("Update available: \(release.version)")
            } else {
                state = userInitiated ? .upToDate : .idle
            }
        } catch {
            Log.error("Update check failed: \(error.localizedDescription)")
            state = userInitiated ? .failed("Couldn't check for updates. \(error.localizedDescription)") : .idle
        }
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Keys.skipped)
        state = .idle
        isPresentingSheet = false
    }

    func dismiss() {
        if case .downloading = state { return }
        if case .installing = state { return }
        if case .available = state {} else { state = .idle }
        isPresentingSheet = false
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cocut/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 404 { throw UpdateError.noReleases }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = payload.assets.first(where: { $0.name == Self.assetName }) else {
            throw UpdateError.missingAsset
        }
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        return Release(
            version: version,
            name: payload.name?.isEmpty == false ? payload.name! : "Cocut \(version)",
            notes: payload.body ?? "",
            downloadURL: asset.browserDownloadURL,
            pageURL: payload.htmlURL
        )
    }

    // MARK: Installing

    func install(_ release: Release) {
        Task { await performInstall(release) }
    }

    private func performInstall(_ release: Release) async {
        let currentApp = Bundle.main.bundleURL

        if currentApp.path(percentEncoded: false).contains("/AppTranslocation/") {
            state = .failed("Move Cocut into your Applications folder, open it from there, then try again.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path(percentEncoded: false)) else {
            state = .failed("Cocut can't write to \(currentApp.deletingLastPathComponent().path(percentEncoded: false)). Download the update from GitHub instead.")
            return
        }

        state = .downloading(release)
        Log.info("Downloading update \(release.version)")
        do {
            let work = FileManager.default.temporaryDirectory.appending(path: "CocutUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
            let zip = work.appending(path: Self.assetName)
            try FileManager.default.moveItem(at: downloaded, to: zip)

            state = .installing(release)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path(percentEncoded: false), work.path(percentEncoded: false)])

            let newApp = work.appending(path: currentApp.lastPathComponent)
            try verify(newApp, expectedVersion: release.version)

            // Swap bundles. replaceItemAt keeps the original location and handles the rename atomically.
            _ = try FileManager.default.replaceItemAt(currentApp, withItemAt: newApp,
                                                      backupItemName: nil, options: [])
            Log.info("Installed \(release.version); relaunching")
            relaunch(currentApp)
        } catch {
            Log.error("Update install failed: \(error.localizedDescription)")
            state = .failed("The update couldn't be installed. \(error.localizedDescription)")
        }
    }

    private func verify(_ app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if version != expectedVersion {
            Log.info("Downloaded bundle reports version \(version ?? "nil"), release says \(expectedVersion)")
        }
    }

    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = app.path(percentEncoded: false).replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open '\(path)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.toolFailed(tool, p.terminationStatus))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: Versions

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case noReleases
    case http(Int)
    case missingAsset
    case invalidBundle
    case toolFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "GitHub sent an unexpected response."
        case .noReleases: return "No releases have been published yet."
        case .http(let code): return "GitHub returned HTTP \(code)."
        case .missingAsset: return "The latest release doesn't include \(Updater.assetName)."
        case .invalidBundle: return "The downloaded file isn't a valid Cocut app."
        case .toolFailed(let tool, let status): return "\(tool) exited with status \(status)."
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlURL = "html_url"
    }
}

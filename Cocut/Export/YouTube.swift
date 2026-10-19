import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// The user's YouTube connection: their own Google "Desktop app" OAuth client (set up once in
/// Google Cloud), a sign-in through the browser, and tokens kept in the Keychain.
@MainActor
@Observable
final class YouTubeAccount {
    enum Status: Equatable {
        case notConfigured
        case signedOut
        case signingIn
        case signedIn(channel: String)
        case failed(String)
    }

    private(set) var status: Status = .notConfigured

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "youtube.clientID"); refreshStatus() }
    }
    var clientSecret: String {
        didSet { Keychain.set(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), for: "clientSecret"); refreshStatus() }
    }

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry = Date.distantPast
    @ObservationIgnored private var receiver: LoopbackReceiver?

    var isConfigured: Bool { !trimmedID.isEmpty && !trimmedSecret.isEmpty }
    var isSignedIn: Bool { if case .signedIn = status { return true } else { return false } }
    private var trimmedID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSecret: String { clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static let scopes = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly"

    init() {
        clientID = UserDefaults.standard.string(forKey: "youtube.clientID") ?? ""
        clientSecret = Keychain.get("clientSecret") ?? ""
        refreshStatus()
        if Keychain.get("refreshToken") != nil {
            Task { await loadChannel() }
        }
    }

    private func refreshStatus() {
        if !isConfigured {
            status = .notConfigured
        } else if Keychain.get("refreshToken") == nil, !isSigningIn {
            status = .signedOut
        }
    }

    private var isSigningIn: Bool { status == .signingIn }

    // MARK: Sign in

    /// Opens Google's sign-in in the browser and waits for it to come back to Cocut.
    func signIn() {
        guard isConfigured else { return }
        status = .signingIn
        Task {
            do {
                let verifier = Self.randomString(64)
                let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
                let state = Self.randomString(24)
                let receiver = LoopbackReceiver()
                self.receiver = receiver
                let port = try await receiver.start()
                let redirect = "http://127.0.0.1:\(port)"
                var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                auth.queryItems = [
                    .init(name: "client_id", value: trimmedID),
                    .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: Self.scopes),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "consent"),
                    .init(name: "state", value: state),
                ]
                NSWorkspace.shared.open(auth.url!)
                let query = try await receiver.waitForRedirect()
                self.receiver = nil
                guard query["state"] == state else { throw YouTubeError.message("The sign-in didn't match. Try again.") }
                if let error = query["error"] { throw YouTubeError.message("Google said: \(error)") }
                guard let code = query["code"] else { throw YouTubeError.message("Google didn't send a sign-in code.") }
                let tokens = try await tokenRequest([
                    "code": code, "client_id": trimmedID, "client_secret": trimmedSecret,
                    "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
                ])
                guard let refresh = tokens.refreshToken else {
                    throw YouTubeError.message("Google didn't grant ongoing access. Sign in again.")
                }
                Keychain.set(refresh, for: "refreshToken")
                accessToken = tokens.accessToken
                accessExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3000) - 60)
                await loadChannel()
                NSApp.activate()
                Log.info("Signed in to YouTube")
            } catch {
                self.receiver?.stop()
                self.receiver = nil
                Log.error("YouTube sign-in failed: \(error.localizedDescription)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        receiver?.stop()
        receiver = nil
        refreshStatus()
        if status == .signingIn { status = .signedOut }
    }

    func signOut() {
        if let token = Keychain.get("refreshToken") {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)")!)
            request.httpMethod = "POST"
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.delete("refreshToken")
        accessToken = nil
        status = isConfigured ? .signedOut : .notConfigured
        Log.info("Signed out of YouTube")
    }

    private func loadChannel() async {
        do {
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true")!)
            request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = json?["items"] as? [[String: Any]]
            let title = (items?.first?["snippet"] as? [String: Any])?["title"] as? String
            status = .signedIn(channel: title ?? "your YouTube channel")
        } catch {
            Log.error("YouTube channel lookup failed: \(error.localizedDescription)")
            if Keychain.get("refreshToken") == nil {
                status = .signedOut
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Tokens

    private struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }

    func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = Keychain.get("refreshToken") else { throw YouTubeError.notSignedIn }
        do {
            let tokens = try await tokenRequest([
                "client_id": trimmedID, "client_secret": trimmedSecret,
                "refresh_token": refresh, "grant_type": "refresh_token",
            ])
            accessToken = tokens.accessToken
            accessExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3000) - 60)
            return tokens.accessToken
        } catch YouTubeError.message(let text) where text.contains("invalid_grant") || text.lowercased().contains("expired")
                    || text.lowercased().contains("revoked") {
            // An expired or revoked sign-in (Google ends test-mode sign-ins after a week).
            Keychain.delete("refreshToken")
            status = .signedOut
            throw YouTubeError.message("Your YouTube sign-in expired. Sign in again.")
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["error_description"] as? String)
                ?? (json?["error"] as? String)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw YouTubeError.message("\(message) (\(http.statusCode))")
        }
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

enum YouTubeError: LocalizedError {
    case notSignedIn
    case message(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to YouTube first (Cocut › Settings › YouTube)."
        case .message(let text): return text
        }
    }
}

enum YouTubePrivacy: String, CaseIterable, Identifiable {
    case unlisted, privateVideo = "private", publicVideo = "public"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unlisted: return "Unlisted (anyone with the link)"
        case .privateVideo: return "Private (only you)"
        case .publicVideo: return "Public"
        }
    }
}

/// Uploads a finished reel with YouTube's resumable upload.
@MainActor
@Observable
final class YouTubeUploader {
    enum State: Equatable {
        case idle
        case uploading(Double)
        case finished(videoID: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isUploading: Bool { if case .uploading = state { return true } else { return false } }

    func upload(file: URL, title: String, description: String, privacy: YouTubePrivacy, account: YouTubeAccount) {
        guard !isUploading else { return }
        state = .uploading(0)
        task = Task {
            do {
                let id = try await run(file: file, title: title, description: description, privacy: privacy, account: account)
                state = .finished(videoID: id)
                Log.info("Uploaded to YouTube: https://youtu.be/\(id)")
            } catch is CancellationError {
                state = .idle
            } catch {
                Log.error("YouTube upload failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }
    func reset() { if !isUploading { state = .idle } }

    private func run(file: URL, title: String, description: String, privacy: YouTubePrivacy,
                     account: YouTubeAccount) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? NSNumber)?.intValue ?? 0
        let metadata: [String: Any] = [
            "snippet": [
                "title": String(title.prefix(100)),
                "description": String(description.prefix(4900)),
                "categoryId": "17", // Sports
                "tags": ["volleyball", "highlights", "recruiting"],
            ],
            "status": [
                "privacyStatus": privacy.rawValue,
                "selfDeclaredMadeForKids": false,
            ],
        ]
        // 1. Start a resumable session.
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(try await account.validAccessToken())", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        try YouTubeAccount.check(startResponse, startData)
        guard let location = (startResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else {
            throw YouTubeError.message("YouTube didn't start the upload.")
        }

        // 2. Send the file.
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 60 * 60
        let watcher = ProgressWatcher { [weak self] fraction in
            Task { @MainActor in
                if case .uploading = self?.state { self?.state = .uploading(fraction) }
            }
        }
        let (data, response) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: watcher)
        try YouTubeAccount.check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else { throw YouTubeError.message("YouTube didn't return the video.") }
        return id
    }

    /// The description, built from the Player Card.
    static func description(for profile: PlayerProfile) -> String {
        var lines: [String] = []
        let headline = [profile.fullName, profile.position, profile.gradYear.isEmpty ? "" : "Class of \(profile.gradYear)"]
            .filter { !$0.isEmpty }
        if !headline.isEmpty { lines.append(headline.joined(separator: " · ")) }
        lines.append("")
        for item in profile.details { lines.append("\(item.label): \(item.value)") }
        let contact = [profile.email, profile.phone, profile.social].filter { !$0.isEmpty }
        if !contact.isEmpty {
            lines.append("")
            lines.append("Contact: " + contact.joined(separator: " · "))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(for profile: PlayerProfile) -> String {
        let year = Calendar.current.component(.year, from: .now)
        let parts = [profile.fullName, profile.position.isEmpty ? "Volleyball" : "\(profile.position)"]
            .filter { !$0.isEmpty }
        return "\(parts.joined(separator: " – ")) Highlights \(year)"
    }
}

/// Reports upload progress from URLSession.
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - Loopback redirect

/// Listens on 127.0.0.1 for the one browser redirect that finishes Google sign-in.
final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "com.mjcocat.Cocut.oauth")

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.continuation = continuation }
            }
        } onCancel: {
            self.stop()
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.continuation?.resume(throwing: CancellationError())
            self.continuation = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let url = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  let items = url.queryItems, !items.isEmpty else {
                // A favicon or other request: answer and keep waiting.
                self.respond(connection, body: "")
                return
            }
            var query: [String: String] = [:]
            for item in items { query[item.name] = item.value ?? "" }
            let ok = query["code"] != nil
            self.respond(connection, body: """
                <html><body style="font-family:-apple-system;text-align:center;padding-top:80px">
                <h2>\(ok ? "You're signed in to YouTube." : "Sign-in didn't finish.")</h2>
                <p>You can close this tab and go back to Cocut.</p></body></html>
                """)
            self.listener?.cancel()
            self.listener = nil
            self.continuation?.resume(returning: query)
            self.continuation = nil
        }
    }

    private func respond(_ connection: NWConnection, body: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A flag shared with a callback queue (only touched on that queue).
private final class Once: @unchecked Sendable {
    var done = false
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.mjcocat.Cocut.youtube"

    static func set(_ value: String, for key: String) {
        delete(key)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

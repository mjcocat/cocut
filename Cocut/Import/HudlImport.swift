import AppKit
import SwiftUI
import WebKit

/// Hudl film, downloaded by the same yt-dlp as YouTube (yt-dlp has no Hudl support of its own:
/// yt-dlp issue 9022). Hudl plays its video as an HLS stream (.m3u8), which yt-dlp downloads and
/// ffmpeg puts together as one .mp4. There are two kinds of link:
///
/// - Public broadcasts (fan.hudl.com/…/watch?b=…): the `b` is "Broadcast<number>" in base64. Hudl's
///   player asks vcloud.hudl.com/api/broadcast/vmap/<number> where the video is (its <Content>):
///   for older broadcasts vcloud…/file/broadcast/<number>.m3u8, for newer ones a vh.hudl.com
///   link (asking for the file/broadcast one directly is refused). No sign-in needed.
/// - Team film (www.hudl.com/watch/video/…): behind Hudl's sign-in. Cocut opens the page in a
///   browser window, the user signs in once (it's remembered), and Cocut picks the stream link
///   (vi.hudl.com/…/video.ondemand.m3u8) up from the page.
/// - Public highlights (www.hudl.com/video/…): plain .mp4 files (360p to 720p) named in the page
///   itself, no sign-in needed.
enum Hudl {
    /// What to download: the stream, the video's name, and the Hudl sign-in to send with it.
    struct Video {
        var stream: String
        var title: String?
        var cookies: [HTTPCookie] = []
    }

    static func isHudl(_ link: String) -> Bool {
        guard let host = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "hudl.com" || host.hasSuffix(".hudl.com") || host.hasSuffix("blueframetech.com")
    }

    /// The video behind a link that needs no sign-in: a public broadcast, a public highlight,
    /// or a video link itself. Nil for team film, which is found by signing in (`HudlBrowser`).
    static func direct(_ link: String) async -> Video? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = link.lowercased()
        if lower.contains(".m3u8") || lower.contains(".mp4") { return Video(stream: link) }
        guard let broadcast = broadcast(in: link) else { return await fromPage(link) }
        async let title = broadcastTitle(broadcast.id)
        let stream = await broadcastStream(broadcast.number)
            ?? "https://vcloud.hudl.com/file/broadcast/\(broadcast.number).m3u8?hfr=1"
        return Video(stream: stream, title: await title)
    }

    /// A broadcast link's id ("QnJvYWRjYXN0ODc2ODA2") and number (876806).
    static func broadcast(in link: String) -> (id: String, number: String)? {
        guard let items = URLComponents(string: link)?.queryItems,
              let id = items.first(where: { $0.name == "b" })?.value, !id.isEmpty else { return nil }
        var padded = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let text = String(data: data, encoding: .utf8),
              text.hasPrefix("Broadcast") else { return nil }
        let number = String(text.dropFirst("Broadcast".count))
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return (id, number)
    }

    /// A page that names its video without signing in (public highlights): the best one on it.
    private static func fromPage(_ link: String) async -> Video? {
        guard let url = URL(string: link) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let stream = best(videos(inPage: html)) else { return nil }
        Log.info("Hudl import: found the video in the page without signing in")
        return Video(stream: stream, title: pageTitle(html))
    }

    /// Video links (streams and .mp4 files on Hudl's servers) named in a page's source.
    static func videos(inPage html: String) -> [String] {
        let text = html.replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "&amp;", with: "&")
        guard let pattern = try? NSRegularExpression(pattern: #"https?://[^"'\s<>\\]+?\.(?:m3u8|mp4)[^"'\s<>\\]*"#,
                                                     options: .caseInsensitive) else { return [] }
        var found: [String] = []
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let link = String(text[r])
            if isHudl(link), !found.contains(link) { found.append(link) }
        }
        return found
    }

    /// The page's og:title ("2 Blocks vs Edwardsville"), else its <title> without " - Hudl".
    static func pageTitle(_ html: String) -> String? {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
        let title = (capture(#"property="og:title"\s+content="([^"]+)""#) ?? capture(#"<title>([^<]+)"#))?
            .replacingOccurrences(of: " - Hudl", with: "")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    /// Where a broadcast's video is, as Hudl's player is told (the <Content> of its VMAP).
    private static func broadcastStream(_ number: String) async -> String? {
        guard let url = URL(string: "https://vcloud.hudl.com/api/broadcast/vmap/\(number)?minify_js=1") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return stream(inVMAP: xml)
    }

    /// "<Content …><![CDATA[https://…m3u8…]]></Content>" → the link.
    static func stream(inVMAP xml: String) -> String? {
        guard let r = xml.range(of: #"<Content[^>]*>\s*<!\[CDATA\[\s*([^\]\s]+)"#, options: .regularExpression) else { return nil }
        let match = String(xml[r])
        guard let start = match.range(of: "CDATA[") else { return nil }
        let link = match[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return link.hasPrefix("http") ? link : nil
    }

    /// A public broadcast's name, from Hudl's public API ("Varsity vs Central"); nil if it can't be read.
    private static func broadcastTitle(_ id: String) async -> String? {
        guard let url = URL(string: "https://www.hudl.com/api/public/graphql/query") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let query = "query Cocut_Broadcast($id: ID!) { broadcast(broadcastId: $id) { title } }"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": id]])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = ((json["data"] as? [String: Any])?["broadcast"] as? [String: Any])?["title"] as? String,
              !title.isEmpty else { return nil }
        return title
    }

    /// The sign-in as a cookies.txt file for yt-dlp (Netscape format).
    static func writeCookies(_ cookies: [HTTPCookie], to file: URL) throws {
        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies {
            let domain = c.domain.hasPrefix(".") || !c.domain.contains(".") ? c.domain : "." + c.domain
            let expires = Int(c.expiresDate?.timeIntervalSince1970 ?? 0)
            lines.append([domain, "TRUE", c.path, c.isSecure ? "TRUE" : "FALSE", String(expires), c.name, c.value]
                .joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Of the stream links on a page, the one to download: Hudl's own film first.
    static func best(_ streams: [String]) -> String? {
        let hls = streams.filter { $0.lowercased().contains(".m3u8") }
        if let stream = hls.first(where: { $0.contains("video.ondemand") }) ?? hls.first(where: { $0.contains("vi.hudl.com") })
            ?? hls.first(where: { $0.contains("blueframetech") }) ?? hls.first {
            return stream
        }
        // Files: the tallest ("…_720.mp4" over "…_480.mp4").
        func height(_ link: String) -> Int {
            guard let r = link.range(of: #"_(\d{3,4})\.mp4"#, options: .regularExpression) else { return 0 }
            return Int(link[r].dropFirst().dropLast(4)) ?? 0
        }
        return streams.filter { $0.lowercased().contains(".mp4") }.max { height($0) < height($1) }
    }

    /// Looks for stream links on the page: in what it has loaded, in its video players, and in its source.
    static let findStreams = #"""
    (() => {
      const found = [];
      const add = (u) => { if (u && !found.includes(u)) found.push(u); };
      const video = /\.(m3u8|mp4)/i, hudl = /^https?:\/\/[^\/]*(hudl\.com|blueframetech\.com)\//i;
      for (const e of performance.getEntriesByType('resource')) if (video.test(e.name) && hudl.test(e.name)) add(e.name);
      for (const v of document.querySelectorAll('video, source')) {
        const u = v.currentSrc || v.src;
        if (u && video.test(u) && hudl.test(u)) add(u);
      }
      const html = document.documentElement.innerHTML.replace(/\\u002F/gi, '/').replace(/\\\//g, '/').replace(/&amp;/g, '&');
      for (const m of html.matchAll(/https?:\/\/[^"'\s<>\\]+?\.(?:m3u8|mp4)[^"'\s<>\\]*/gi)) if (hudl.test(m[0])) add(m[0]);
      return JSON.stringify({ streams: found, title: document.title });
    })()
    """#
}

/// A browser window onto Hudl: the user signs in (once; it's remembered) and opens the video,
/// and Cocut watches the page for its stream.
struct HudlBrowser: View {
    let link: String
    let onChoose: (Hudl.Video) -> Void
    let onCancel: () -> Void

    @State private var streams: [String] = []
    @State private var title: String?
    @State private var chosen: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Design.Space.m) {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("Find the video on Hudl").font(.headline)
                    Text(streams.isEmpty
                         ? "Sign in to Hudl if it asks (Cocut remembers it), then open the video and press play. Cocut picks it up from the page."
                         : "Found \(streams.count == 1 ? "the video" : "\(streams.count) videos on this page"). Download it, or open another one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if streams.count > 1 {
                    Picker("Video", selection: $chosen) {
                        ForEach(Array(streams.enumerated()), id: \.element) { k, s in
                            Text("Video \(k + 1)").tag(Optional(s))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Download") { Task { await download() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
            .padding(Design.Space.l)
            Divider()
            HudlWebView(link: link) { found, pageTitle in
                guard found != streams else { return }
                streams = found
                title = pageTitle
                if chosen == nil || !found.contains(chosen ?? "") { chosen = Hudl.best(found) }
            }
        }
        .frame(minWidth: 900, minHeight: 680)
    }

    private func download() async {
        guard let chosen else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.lowercased().hasSuffix("hudl.com") }
        // "Hudl" alone, or "Video - Hudl", says nothing about the video.
        let name = title.map { $0.replacingOccurrences(of: " - Hudl", with: "").replacingOccurrences(of: " | Hudl", with: "")
            .replacingOccurrences(of: " • Hudl", with: "") }
            .flatMap { $0.trimmingCharacters(in: .whitespaces).lowercased() == "hudl" ? nil : $0 }
        let picked = URL(string: chosen).map { "\($0.host ?? "")\($0.path)" } ?? chosen
        Log.info("Hudl import: picked \(picked) (1 of \(streams.count) stream(s) on the page), \(cookies.count) sign-in cookie(s)")
        onChoose(Hudl.Video(stream: chosen, title: name, cookies: cookies))
    }
}

/// The page itself, checked for streams every second.
private struct HudlWebView: NSViewRepresentable {
    let link: String
    let onStreams: ([String], String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStreams: onStreams) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { view.load(URLRequest(url: url)) }
        context.coordinator.watch(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onStreams = onStreams
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    @MainActor
    final class Coordinator {
        var onStreams: ([String], String?) -> Void
        var timer: Timer?

        init(onStreams: @escaping ([String], String?) -> Void) { self.onStreams = onStreams }

        func watch(_ view: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let view else { return }
                    guard let text = try? await view.evaluateJavaScript(Hudl.findStreams) as? String,
                          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                    let streams = (json["streams"] as? [String]) ?? []
                    self.onStreams(streams, json["title"] as? String)
                }
            }
        }
    }
}

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
/// - Team film (www.hudl.com/watch/video/…, app.hudl.com/watch/team/…/analyze?v=…): behind Hudl's
///   sign-in. Cocut opens the page in a browser window, the user signs in once (it's remembered),
///   and Cocut reads the page (`scanPage`): the video's name and stream from Hudl's API
///   (`video(videoId:)`, asked with the page's sign-in), and the moments the page lists. A moment
///   ("Set 1 · Rally 16 · Attack") is a few seconds of that one stream (its start and end in ms),
///   not a video of its own: Cocut downloads just that part (`YouTubeImporter`, with `trimmed`).
///   The streams themselves (vh.hudl.com/…/video.ondemand.m3u8) need no sign-in.
/// - Public highlights (www.hudl.com/video/…): plain .mp4 files (360p to 720p) named in the page
///   itself, no sign-in needed.
enum Hudl {
    /// What to download: the stream, the video's name, and the Hudl sign-in to send with it.
    struct Video {
        var stream: String
        var title: String?
        var cookies: [HTTPCookie] = []
        /// Just this part of the stream (seconds), for a moment; nil for the whole video.
        var section: ClosedRange<Double>? = nil
    }

    // MARK: What a team film page lists

    /// What `scanPage` reads from a Hudl page.
    struct Page: Decodable, Equatable {
        var streams: [String] = []
        var title: String?
        var moments: [Moment] = []
        var videos: [PageVideo] = []
    }

    /// A video, as Hudl's API describes it: "GBS", with one stream per camera angle.
    struct PageVideo: Decodable, Equatable {
        var id: String
        var title: String?
        var durationMs: Double?
        var playbackUrl: String?
        var streams: [Stream]?

        struct Stream: Decodable, Equatable {
            var name: String?
            var durationMs: Double?
            var playbackUrl: String?
        }

        /// Its streams with links ("Angle 1"), or the video's own link when it lists none.
        var playable: [(name: String?, link: String)] {
            let listed = (streams ?? []).compactMap { s in s.playbackUrl.map { (name: s.name, link: $0) } }
            if !listed.isEmpty { return listed }
            return playbackUrl.map { [(name: nil, link: $0)] } ?? []
        }
    }

    /// A tagged moment in a video: where it is (ms into the video's stream) and what happened.
    struct Moment: Decodable, Equatable {
        var id: String
        var videoId: String
        var startMs: Double
        var endMs: Double
        var rallyStartMs: Double?
        var rallyEndMs: Double?
        var period: String?
        var rally: String?
        var type: String?
        var subType: String?
        var result: String?
        var assisted: String?
        var scoreOne: String?
        var scoreTwo: String?

        /// "Set 1 · Rally 16 · 8–7"
        var place: String {
            var parts: [String] = []
            if let period { parts.append("\(Hudl.volleyball.contains(type ?? "") ? "Set" : "Period") \(period)") }
            if let rally { parts.append("Rally \(rally)") }
            if let scoreOne, let scoreTwo { parts.append("\(scoreOne)–\(scoreTwo)") }
            return parts.joined(separator: " · ")
        }

        /// "Attack Kill", "Free Ball Receive", "Block Assist", as Hudl's list says it.
        var play: String {
            if type == "block", assisted == "true" { return "Block Assist" }
            if let subType { return Hudl.words(subType) }
            return [type, result].compactMap { $0.map(Hudl.words) }.joined(separator: " ")
        }

        /// "Set 1 · Rally 16 · Attack Kill" (the score is left out of names).
        var name: String {
            var parts: [String] = []
            if let period { parts.append("\(Hudl.volleyball.contains(type ?? "") ? "Set" : "Period") \(period)") }
            if let rally { parts.append("Rally \(rally)") }
            if !play.isEmpty { parts.append(play) }
            return parts.isEmpty ? "Moment" : parts.joined(separator: " · ")
        }

        /// The moment's part of the stream, or its whole rally (when Hudl knows it), in seconds.
        func section(wholeRally: Bool) -> ClosedRange<Double> {
            if wholeRally, let a = rallyStartMs, let b = rallyEndMs, b > a {
                // The rally around the moment, never cutting the moment itself short.
                return min(a, startMs) / 1000 ... max(b, endMs) / 1000
            }
            return startMs / 1000 ... max(endMs, startMs + 1000) / 1000
        }
    }

    /// Hudl's volleyball moment types (their periods are sets).
    static let volleyball: Set<String> = ["attack", "block", "pass", "serve", "set", "dig", "reception", "freeBall"]

    /// "freeBallReceive" → "Free Ball Receive".
    static func words(_ camel: String) -> String {
        var out = ""
        for c in camel {
            if c.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty || out.last == " " ? Character(c.uppercased()) : c)
        }
        return out
    }

    /// One thing the Hudl window offers to download: a whole video (one angle of it), or a moment.
    struct Choice: Identifiable, Hashable {
        enum Kind: Hashable { case whole, moment, stream }
        var id: String
        var kind: Kind
        /// What the menu says ("GBS · 42:56", "Set 1 · Rally 16 · 8–7 · Attack").
        var label: String
        /// What the download is called ("GBS – Set 1 · Rally 16 · Attack").
        var title: String?
        var link: String
        var moment: Moment?

        static func == (a: Choice, b: Choice) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// The page's videos and moments, in the order the window lists them. Without what the API
    /// says (an older page), the stream links found on the page, numbered.
    static func choices(on page: Page) -> [Choice] {
        var out: [Choice] = []
        var linkFor: [String: (title: String?, link: String)] = [:]
        for video in page.videos {
            let streams = video.playable
            for (k, stream) in streams.enumerated() {
                if k == 0 { linkFor[video.id] = (video.title, stream.link) }
                var label = video.title ?? "Video"
                if streams.count > 1, let name = stream.name { label += " (\(name))" }
                if let ms = video.durationMs, ms > 0 { label += " · \(clock(ms / 1000))" }
                let title = streams.count > 1 && stream.name != nil ? "\(video.title ?? "Hudl video") (\(stream.name!))" : video.title
                out.append(Choice(id: "video:\(video.id):\(k)", kind: .whole, label: label, title: title, link: stream.link))
            }
        }
        for moment in page.moments {
            guard let video = linkFor[moment.videoId] else { continue }
            let label = [moment.place, moment.play].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(Choice(id: "moment:\(moment.id):\(moment.startMs)", kind: .moment, label: label.isEmpty ? "Moment" : label,
                              title: [video.title, moment.name].compactMap { $0 }.joined(separator: " – "),
                              link: video.link, moment: moment))
        }
        if out.isEmpty {
            for (k, stream) in page.streams.enumerated() {
                out.append(Choice(id: "stream:\(stream)", kind: .stream, label: "Video \(k + 1)", title: nil, link: stream))
            }
        }
        return out
    }

    /// 2575.6 → "42:55"; 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Part of a stream

    /// Of an HLS master playlist's variants, the one to download: H.264 up to 1080p, the sharpest
    /// (Hudl also offers 1080p HEVC, which older Macs can't play). Nil when `master` isn't one.
    static func variant(in master: String, base: URL) -> URL? {
        let lines = master.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        struct Variant { var url: URL; var bandwidth: Int; var height: Int; var h264: Bool }
        var found: [Variant] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let uri = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            func value(_ pattern: String) -> String? {
                guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
                return String(line[r])
            }
            let bandwidth = value(#"(?<=BANDWIDTH=)\d+"#).flatMap { Int($0) } ?? 0
            let height = value(#"(?<=RESOLUTION=\d{1,5}x)\d+"#).flatMap { Int($0) } ?? 0
            let codecs = value(#"(?<=CODECS=")[^"]*"#) ?? ""
            found.append(Variant(url: url, bandwidth: bandwidth, height: height, h264: codecs.isEmpty || codecs.contains("avc1")))
        }
        guard !found.isEmpty else { return nil }
        let fits = found.filter { $0.height <= 1080 }
        let pick = fits.filter(\.h264).max { $0.bandwidth < $1.bandwidth }
            ?? fits.max { $0.bandwidth < $1.bandwidth } ?? found.min { $0.bandwidth < $1.bandwidth }
        return pick?.url
    }

    /// A media playlist cut down to the segments that cover `from`…`to` (seconds into the stream),
    /// with every link made absolute, and where its first segment starts. Hudl's film can be
    /// several recordings in one stream, each with its own header (#EXT-X-MAP): ffmpeg can't seek
    /// into such a stream past the first one ("partial file"), but plays this short list fine.
    static func trimmed(_ playlist: String, base: URL, from start: Double, to end: Double) -> (text: String, start: Double)? {
        func absolute(_ uri: String) -> String { URL(string: uri, relativeTo: base)?.absoluteString ?? uri }
        func absoluteTag(_ line: String) -> String {
            guard let r = line.range(of: #"(?<=URI=")[^"]+"#, options: .regularExpression) else { return line }
            return line.replacingCharacters(in: r, with: absolute(String(line[r])))
        }
        var out: [String] = []
        var t = 0.0, duration: Double?, longest = 1.0
        var map: String?, key: String?, writtenMap: String?, writtenKey: String?
        var broke = false, first: Double?
        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MAP:") { map = absoluteTag(line) }
            else if line.hasPrefix("#EXT-X-KEY:") { key = absoluteTag(line) }
            else if line == "#EXT-X-DISCONTINUITY" { broke = true }
            else if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst(8).prefix { $0 != "," }) }
            else if !line.hasPrefix("#") {
                let d = duration ?? 0
                if t + d > start, t < end {
                    if first != nil, broke || map != writtenMap || key != writtenKey { out.append("#EXT-X-DISCONTINUITY") }
                    if first == nil { first = t }
                    if let map, map != writtenMap { out.append(map); writtenMap = map }
                    if let key, key != writtenKey { out.append(key); writtenKey = key }
                    out.append("#EXTINF:\(d),")
                    out.append(absolute(line))
                    longest = max(longest, d)
                }
                t += d
                duration = nil
                broke = false
            }
        }
        guard let first else { return nil }
        let head = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
                    "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        return ((head + out + ["#EXT-X-ENDLIST"]).joined(separator: "\n") + "\n", first)
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

    /// Reads a team film page (run with `callAsyncJavaScript`, in the page's own world, which is
    /// where its components keep their data). Returns `Page` as JSON:
    /// - the stream links it has loaded or names (what older pages offer);
    /// - the moments it lists, after its own filters ("#14 Lilah Cocat"): Hudl's player keeps them
    ///   as objects with a videoId and start/end times, held by the components that draw the rows;
    /// - each video's name and streams, from Hudl's API, asked once per video with the page's sign-in.
    static let scanPage = #"""
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

    const isMoment = (o) => o && typeof o === 'object' && typeof o.videoId === 'string'
      && typeof o.startTimeMs === 'number' && typeof o.endTimeMs === 'number';
    const counts = new Map();
    for (const el of document.querySelectorAll('body *')) {
      const key = Object.keys(el).find(k => k.startsWith('__reactFiber'));
      if (!key) continue;
      let f = el[key];
      for (let i = 0; f && i < 12; i++, f = f.return) {
        const p = f.memoizedProps;
        if (!p || typeof p !== 'object') continue;
        for (const k in p) {
          const v = p[k];
          if (Array.isArray(v) && v.length && v.length < 2000 && isMoment(v[0]) && v.every(isMoment)) counts.set(v, (counts.get(v) || 0) + 1);
        }
      }
    }
    // The list the most rows draw from; the shorter one when even (a filtered list over everything).
    let list = [], best = 0;
    for (const [v, n] of counts) if (n > best || (n === best && v.length < list.length)) { list = v; best = n; }
    const tags = (m) => {
      const out = {};
      for (const x of [m, ...(Array.isArray(m.moments) ? m.moments : [])])
        for (const t of (Array.isArray(x.tags) ? x.tags : []))
          if (t && t.key && !(t.key in out)) out[t.key] = Array.isArray(t.values) ? t.values : [t.values];
      return out;
    };
    const moments = list.map(c => {
      // The clip shown (4 s) sits inside its moment (8 s, starting before the contact): take the moment.
      const inner = Array.isArray(c.moments) && c.moments[0] && isMoment(c.moments[0]) ? c.moments[0] : c;
      const t = tags(c), one = (k) => t[k] && t[k].length ? String(t[k][0]) : null;
      return { id: String(c.id || ''), videoId: c.videoId,
               startMs: Math.min(c.startTimeMs, inner.startTimeMs), endMs: Math.max(c.endTimeMs, inner.endTimeMs),
               rallyStartMs: Number(one('rallyStartTime')) || null, rallyEndMs: Number(one('rallyEndTime')) || null,
               period: one('period') || (c.periodInfo && c.periodInfo.number ? String(c.periodInfo.number) : null),
               rally: one('rally'), type: one('type'), subType: one('subType'), result: one('result'),
               assisted: one('assistedBlock'), scoreOne: one('scoreTeamOne'), scoreTwo: one('scoreTeamTwo') };
    });

    const ids = new Set(moments.map(m => m.videoId));
    const v = new URLSearchParams(location.search).get('v');
    if (v) ids.add(v);
    window.__cocutVideos = window.__cocutVideos || {};
    const query = 'query Cocut_Video($videoId: String!) { video(videoId: $videoId) { id title durationMs playbackUrl '
      + 'streams { name durationMs playbackUrl } } }';
    for (const id of ids) {
      if (id in window.__cocutVideos) continue;
      window.__cocutVideos[id] = null;
      try {
        const r = await fetch('https://www.hudl.com/api/graphql/query', { method: 'POST', credentials: 'include',
          headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ query, variables: { videoId: id } }) });
        const j = await r.json();
        if (j && j.data && j.data.video) window.__cocutVideos[id] = j.data.video;
        else delete window.__cocutVideos[id];
      } catch (e) { delete window.__cocutVideos[id]; }
    }
    const videos = [...ids].map(id => window.__cocutVideos[id]).filter(Boolean);
    return JSON.stringify({ streams: found, title: document.title, moments, videos });
    """#
}

/// A browser window onto Hudl: the user signs in (once; it's remembered) and opens the video,
/// and Cocut reads the page for what it can download: each video by name, and each moment the
/// page lists ("Set 1 · Rally 16 · 8–7 · Attack").
struct HudlBrowser: View {
    let link: String
    let onChoose: (Hudl.Video) -> Void
    let onCancel: () -> Void

    @State private var page = Hudl.Page()
    @State private var chosen: Hudl.Choice?
    /// For a moment: its whole rally rather than just the moment.
    @State private var wholeRally = false

    private var choices: [Hudl.Choice] { Hudl.choices(on: page) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Design.Space.m) {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("Find the video on Hudl").font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if choices.count > 1 { picker }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Download") { Task { await download() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
            .padding(Design.Space.l)
            Divider()
            HudlWebView(link: link) { found in
                guard found != page else { return }
                page = found
                let now = Hudl.choices(on: found)
                if let chosen, let same = now.first(where: { $0.id == chosen.id }) {
                    self.chosen = same
                } else {
                    // The whole video first; else (older pages) the best stream link.
                    chosen = now.first { $0.kind == .whole }
                        ?? Hudl.best(found.streams).flatMap { best in now.first { $0.link == best } } ?? now.first
                }
            }
        }
        .frame(minWidth: 900, minHeight: 680)
    }

    private var summary: String {
        let videos = choices.filter { $0.kind == .whole }.count
        let moments = choices.filter { $0.kind == .moment }.count
        if choices.isEmpty {
            return "Sign in to Hudl if it asks (Cocut remembers it), then open the video and press play. Cocut picks it up from the page."
        }
        if videos > 0 {
            let what = moments > 0 ? "the whole video or one of the \(moments) moment\(moments == 1 ? "" : "s") this page lists"
                                   : (videos == 1 ? "the video" : "one of the \(videos) videos on this page")
            return "Choose \(what), then Download. A moment comes in as a clip."
        }
        return "Found \(choices.count == 1 ? "the video" : "\(choices.count) videos on this page"). Download it, or open another one."
    }

    @ViewBuilder private var picker: some View {
        VStack(alignment: .trailing, spacing: Design.Space.xs) {
            Picker("Video", selection: $chosen) {
                let whole = choices.filter { $0.kind != .moment }
                let moments = choices.filter { $0.kind == .moment }
                if moments.isEmpty {
                    ForEach(whole) { Text($0.label).tag(Optional($0)) }
                } else {
                    Section("Whole video") {
                        ForEach(whole) { Text($0.label).tag(Optional($0)) }
                    }
                    Section("Moments (\(moments.count))") {
                        ForEach(moments) { Text($0.label).tag(Optional($0)) }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 320)
            if let moment = chosen?.moment, moment.rallyStartMs != nil {
                Toggle("Whole rally", isOn: $wholeRally)
                    .help("Download the whole rally around this moment, not just the moment itself.")
            }
        }
    }

    private func download() async {
        guard let chosen else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.lowercased().hasSuffix("hudl.com") }
        var name = chosen.title
        if name == nil {
            // "Hudl" alone, or "Video - Hudl", says nothing about the video.
            name = page.title.map { $0.replacingOccurrences(of: " - Hudl", with: "").replacingOccurrences(of: " | Hudl", with: "")
                .replacingOccurrences(of: " • Hudl", with: "") }
                .flatMap { $0.trimmingCharacters(in: .whitespaces).lowercased() == "hudl" ? nil : $0 }
        }
        let section = chosen.moment?.section(wholeRally: wholeRally)
        if section != nil, wholeRally, let base = chosen.title, let moment = chosen.moment, moment.rallyStartMs != nil {
            name = base.replacingOccurrences(of: moment.name, with: moment.name + " (rally)")
        }
        let picked = URL(string: chosen.link).map { "\($0.host ?? "")\($0.path)" } ?? chosen.link
        Log.info("Hudl import: picked \(chosen.label) (\(picked))"
                 + (section.map { String(format: ", %.1f–%.1f s", $0.lowerBound, $0.upperBound) } ?? "")
                 + "; the page lists \(page.videos.count) video(s), \(page.moments.count) moment(s), \(page.streams.count) stream link(s); "
                 + "\(cookies.count) sign-in cookie(s)")
        onChoose(Hudl.Video(stream: chosen.link, title: name, cookies: cookies, section: section))
    }
}

/// The page itself, read every second (`Hudl.scanPage`).
private struct HudlWebView: NSViewRepresentable {
    let link: String
    let onPage: (Hudl.Page) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }

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
        context.coordinator.onPage = onPage
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    @MainActor
    final class Coordinator {
        var onPage: (Hudl.Page) -> Void
        var timer: Timer?
        /// A scan still running (the API can be slow): the next tick waits for it.
        private var busy = false

        init(onPage: @escaping (Hudl.Page) -> Void) { self.onPage = onPage }

        func watch(_ view: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let view, !self.busy else { return }
                    self.busy = true
                    defer { self.busy = false }
                    guard let text = try? await view.callAsyncJavaScript(Hudl.scanPage, contentWorld: .page) as? String,
                          let page = try? JSONDecoder().decode(Hudl.Page.self, from: Data(text.utf8)) else { return }
                    self.onPage(page)
                }
            }
        }
    }
}

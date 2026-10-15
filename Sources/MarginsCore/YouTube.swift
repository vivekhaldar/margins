import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Material Margins fetched itself and hands to the model alongside the instruction.
public struct SourceMaterial: Sendable, Equatable {
    public var url: String
    public var title: String
    public var byline: String
    public var kind: String
    public var text: String
    public var truncated: Bool

    public init(url: String, title: String, byline: String = "", kind: String, text: String, truncated: Bool = false) {
        self.url = url
        self.title = title
        self.byline = byline
        self.kind = kind
        self.text = text
        self.truncated = truncated
    }

    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

/// Fetches YouTube captions directly. Agents usually can't: the watch page has no transcript in
/// its HTML, web search doesn't index captions, and sandboxes often block network commands.
public enum YouTube {
    public enum FetchError: LocalizedError {
        case page, noCaptions(String), unplayable(String)
        public var errorDescription: String? {
            switch self {
            case .page: return "Couldn't read the YouTube page."
            case .noCaptions(let t): return "“\(t)” has no captions."
            case .unplayable(let why): return "YouTube refused: \(why)"
            }
        }
    }

    /// Video ids referenced in `text`, in order, without duplicates.
    public static func videoIDs(in text: String) -> [String] {
        let pattern = #"(?:youtube\.com/(?:watch\?(?:[^\s]*?&)?v=|shorts/|live/|embed/)|youtu\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let id = String(text[r])
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    struct Track: Equatable {
        var language: String
        var auto: Bool
        var url: String
    }

    /// Prefer human captions in a preferred language, then auto-captions in it, then any human track.
    static func pick(_ tracks: [Track], languages: [String]) -> Track? {
        for auto in [false, true] {
            for lang in languages {
                if let t = tracks.first(where: { $0.auto == auto && ($0.language == lang || $0.language.hasPrefix(lang + "-")) }) {
                    return t
                }
            }
        }
        return tracks.first(where: { !$0.auto }) ?? tracks.first
    }

    /// Caption XML (`<text>` or srv3 `<p>` cues) → readable paragraphs, breaking on long pauses.
    public static func transcript(fromXML xml: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<(?:text|p)\b([^>]*)>([\s\S]*?)</(?:text|p)>"#),
              let startRE = try? NSRegularExpression(pattern: #"\b(start|t)="([\d.]+)""#) else { return "" }
        var paragraphs: [String] = [], current = "", lastStart = -1.0, paraStart = 0.0
        let ns = xml as NSString
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1)) as NSString
            var start = lastStart
            if let sm = startRE.firstMatch(in: attrs as String, range: NSRange(location: 0, length: attrs.length)) {
                let value = Double(attrs.substring(with: sm.range(at: 2))) ?? lastStart
                start = attrs.substring(with: sm.range(at: 1)) == "t" ? value / 1000 : value
            }
            var cue = ns.substring(with: m.range(at: 2))
            cue = cue.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            cue = decodeEntities(decodeEntities(cue))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !cue.isEmpty else { continue }
            let pause = lastStart >= 0 && start - lastStart > 4
            let sentenceEnd = current.hasSuffix(".") || current.hasSuffix("?") || current.hasSuffix("!")
            if !current.isEmpty && (pause || (start - paraStart > 45 && sentenceEnd) || current.count > 1200) {
                paragraphs.append(current)
                current = ""
            }
            if current.isEmpty { paraStart = start }
            current += current.isEmpty ? cue : " " + cue
            lastStart = start
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let ns = out as NSString
            var result = "", last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let n = UInt32(ns.substring(with: m.range(at: 2)), radix: m.range(at: 1).length > 0 ? 16 : 10)
                result += n.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            out = result + ns.substring(from: last)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36",
        "Accept-Language": "en-US,en;q=0.9",
    ]

    private static func get(_ url: URL, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func apiKey(inWatchPage page: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #""INNERTUBE_API_KEY"\s*:\s*"([^"]+)""#),
              let m = re.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let r = Range(m.range(at: 1), in: page) else { return nil }
        return String(page[r])
    }

    /// Fetch title, channel and transcript for one video. `maxCharacters` caps the transcript.
    public static func fetch(id: String, languages: [String] = preferredLanguages(), maxCharacters: Int = 150_000) async throws -> SourceMaterial {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        let page = String(decoding: try await get(URL(string: watch)!), as: UTF8.self)
        guard let key = apiKey(inWatchPage: page) else { throw FetchError.page }
        let body = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "ANDROID", "clientVersion": "20.10.38"]],
            "videoId": id,
        ])
        let player = try await get(URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(key)")!, body: body)
        guard let json = try JSONSerialization.jsonObject(with: player) as? [String: Any] else { throw FetchError.page }
        let details = json["videoDetails"] as? [String: Any] ?? [:]
        let title = details["title"] as? String ?? "YouTube video \(id)"
        let author = details["author"] as? String ?? ""
        let status = json["playabilityStatus"] as? [String: Any]
        if let s = status?["status"] as? String, s != "OK", details.isEmpty {
            throw FetchError.unplayable(status?["reason"] as? String ?? s)
        }
        let renderer = (json["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let tracks = (renderer?["captionTracks"] as? [[String: Any]] ?? []).compactMap { t -> Track? in
            guard let url = t["baseUrl"] as? String, let lang = t["languageCode"] as? String else { return nil }
            return Track(language: lang, auto: (t["kind"] as? String) == "asr", url: url)
        }
        guard let track = pick(tracks, languages: languages),
              let url = URL(string: track.url.replacingOccurrences(of: "&fmt=srv3", with: "")) else {
            throw FetchError.noCaptions(title)
        }
        var text = transcript(fromXML: String(decoding: try await get(url), as: UTF8.self))
        guard !text.isEmpty else { throw FetchError.noCaptions(title) }
        let truncated = text.count > maxCharacters
        if truncated { text = String(text.prefix(maxCharacters)) }
        var byline = author
        if let secs = Int(details["lengthSeconds"] as? String ?? "") {
            byline += (byline.isEmpty ? "" : " · ") + String(format: "%d:%02d", secs / 60, secs % 60)
        }
        let kind = "YouTube transcript (\(track.language)\(track.auto ? ", auto-generated" : ""))"
        return SourceMaterial(url: watch, title: title, byline: byline, kind: kind, text: text, truncated: truncated)
    }

    public static func preferredLanguages() -> [String] {
        var langs = Locale.preferredLanguages.map { String($0.prefix(while: { $0 != "-" })) }
        langs.append("en")
        var seen = Set<String>()
        return langs.filter { seen.insert($0).inserted }
    }
}

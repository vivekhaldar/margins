import CryptoKit
import Foundation

/// A binary resource (image) stored inside the `.margins` file and referenced from the HTML as
/// `margins-asset://img/<hash>.<ext>`. Content-addressed, so every version snapshot can reference
/// the same image without duplicating it.
public struct Asset: Codable, Equatable, Sendable {
    public var mime: String
    public var data: Data
    public init(mime: String, data: Data) { self.mime = mime; self.data = data }

    public var fileExtension: String { Asset.extensions[mime] ?? "bin" }

    static let extensions: [String: String] = [
        "image/svg+xml": "svg", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
        "image/webp": "webp", "image/heic": "heic", "image/tiff": "tiff",
    ]
    public static func mime(forExtension ext: String) -> String? {
        let e = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
        return extensions.first { $0.value == e }?.key
    }
}

public extension MarginsDocument {
    static let assetScheme = "margins-asset"

    /// `margins-asset://img/<hash>.<ext>` → `<hash>`.
    static func assetID(fromSrc src: String) -> String? {
        guard src.hasPrefix("\(assetScheme)://img/") else { return nil }
        let last = src.split(separator: "/").last.map(String.init) ?? ""
        let id = last.split(separator: ".").first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }

    func assetSrc(_ id: String) -> String {
        "\(Self.assetScheme)://img/\(id).\(assets[id]?.fileExtension ?? "bin")"
    }

    /// Store `data` and return its `margins-asset://` URL.
    @discardableResult
    mutating func addAsset(_ data: Data, mime: String) -> String {
        let id = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        if assets[id] == nil { assets[id] = Asset(mime: mime, data: data) }
        return assetSrc(id)
    }

    /// Move inline `<svg>…</svg>` and `data:image/…` URIs out of `html` into the asset store,
    /// replacing them with `<img src="margins-asset://…">`.
    mutating func internalizeImages(_ html: String) -> String {
        var out = html
        // Inline SVG (as written by the agent).
        if let re = try? NSRegularExpression(pattern: #"<svg\b[\s\S]*?</svg\s*>"#, options: [.caseInsensitive]) {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                var svg = ns.substring(with: m.range)
                if !svg.contains("xmlns=") {
                    svg = svg.replacingOccurrences(of: "<svg", with: "<svg xmlns=\"http://www.w3.org/2000/svg\"",
                                                   options: [.caseInsensitive, .anchored])
                }
                let src = addAsset(Data(svg.utf8), mime: "image/svg+xml")
                result += "<img src=\"\(src)\" alt=\"\(Self.attrEscape(Self.svgTitle(svg)))\">"
                cursor = m.range.location + m.range.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        // data: URIs in src attributes.
        if let re = try? NSRegularExpression(pattern: #"src\s*=\s*"data:(image/[a-z0-9.+-]+);base64,([A-Za-z0-9+/=\s]+)""#,
                                             options: [.caseInsensitive]) {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                let mime = ns.substring(with: m.range(at: 1)).lowercased()
                let b64 = ns.substring(with: m.range(at: 2)).filter { !$0.isWhitespace }
                if let data = Data(base64Encoded: b64) {
                    result += "src=\"\(addAsset(data, mime: mime))\""
                } else {
                    result += ns.substring(with: m.range)
                }
                cursor = m.range.location + m.range.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        return out
    }

    /// For prompts: show stored SVGs to the model as inline `<svg>` so it can read and edit diagrams.
    func expandSVGForPrompt(_ html: String, maxBytes: Int = 24_000) -> String {
        guard html.contains("\(Self.assetScheme)://"),
              let re = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc="(margins-asset://img/[^"]+)"[^>]*>"#,
                                                options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let src = ns.substring(with: m.range(at: 1))
            if let id = Self.assetID(fromSrc: src), let a = assets[id], a.mime == "image/svg+xml",
               a.data.count <= maxBytes, let svg = String(data: a.data, encoding: .utf8) {
                result += svg
            } else {
                result += ns.substring(with: m.range)
            }
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Asset ids referenced by `html`.
    static func assetIDs(in html: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"margins-asset://img/([0-9a-f]+)"#) else { return [] }
        let ns = html as NSString
        return Set(re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// Drop assets no longer referenced by the current document or any version.
    mutating func pruneAssets() {
        guard !assets.isEmpty else { return }
        var used = Self.assetIDs(in: html)
        for v in versions { used.formUnion(Self.assetIDs(in: v.html)) }
        assets = assets.filter { used.contains($0.key) }
    }

    /// Replace asset URLs in `html` with self-contained `data:` URIs (for HTML export).
    func inliningAssets(_ html: String) -> String {
        var out = html
        for id in Self.assetIDs(in: html) {
            guard let a = assets[id] else { continue }
            out = out.replacingOccurrences(of: assetSrc(id), with: "data:\(a.mime);base64,\(a.data.base64EncodedString())")
        }
        return out
    }

    private static func svgTitle(_ svg: String) -> String {
        if let r = svg.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let t = String(svg[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let r = svg.range(of: #"aria-label="([^"]*)""#, options: .regularExpression) {
            return String(svg[r]).replacingOccurrences(of: #"^aria-label=""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
        }
        return "Diagram"
    }

    private static func attrEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}

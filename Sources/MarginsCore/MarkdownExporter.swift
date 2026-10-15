import Foundation

/// Converts the editor's HTML into Markdown.
///
/// Pending tracked changes (`<div class="chg"><del>old</del><ins>new</ins>…</div>`) are
/// exported as the accepted text: the `<del>` side is kept and the proposed `<ins>` side is
/// dropped, so the Markdown always reflects what the author has actually signed off on.
public enum MarkdownExporter {
    public static func markdown(fromHTML html: String) -> String {
        let root = HTMLNode.parse(html)
        var r = Renderer()
        let out = r.blocks(root.children, indent: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

// MARK: - tiny tolerant HTML tree

final class HTMLNode {
    let tag: String          // "" for text nodes, "#root" for the root
    var attrs: [String: String] = [:]
    var text = ""
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(tag: String) { self.tag = tag }

    var classes: Set<String> { Set((attrs["class"] ?? "").split(separator: " ").map(String.init)) }

    static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "wbr", "col", "source"]
    static let autoClose: [String: Set<String>] = [
        "p": ["p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "table", "hr"],
        "li": ["li"],
    ]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(tag: "#root")
        var cur = root
        let s = Array(html.unicodeScalars)
        var i = 0
        var buf = ""

        func flush() {
            guard !buf.isEmpty else { return }
            let t = HTMLNode(tag: "")
            t.text = decodeEntities(buf)
            t.parent = cur
            cur.children.append(t)
            buf = ""
        }

        while i < s.count {
            if s[i] == "<" {
                // comment
                if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                    flush()
                    var j = i + 4
                    while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                    i = min(s.count, j + 3)
                    continue
                }
                var j = i + 1
                var quote: Unicode.Scalar?
                while j < s.count {
                    let c = s[j]
                    if let q = quote { if c == q { quote = nil } }
                    else if c == "\"" || c == "'" { quote = c }
                    else if c == ">" { break }
                    j += 1
                }
                guard j < s.count else { buf.unicodeScalars.append(contentsOf: s[i...]); break }
                let raw = String(String.UnicodeScalarView(s[(i + 1)..<j]))
                i = j + 1
                guard let first = raw.unicodeScalars.first, first == "/" || first == "!" || CharacterSet.letters.contains(first) else {
                    buf += "<" + raw + ">"
                    continue
                }
                flush()
                if first == "!" { continue } // doctype
                if first == "/" {
                    let name = raw.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                    var n: HTMLNode? = cur
                    while let x = n, x.tag != name, x.tag != "#root" { n = x.parent }
                    if let x = n, x.tag == name, let p = x.parent { cur = p }
                    continue
                }
                let (name, attrs, selfClosing) = parseTag(raw)
                if let closes = autoClose[cur.tag], closes.contains(name), let p = cur.parent { cur = p }
                let el = HTMLNode(tag: name)
                el.attrs = attrs
                el.parent = cur
                cur.children.append(el)
                if !selfClosing && !voidTags.contains(name) { cur = el }
            } else {
                buf.unicodeScalars.append(s[i])
                i += 1
            }
        }
        flush()
        return root
    }

    private static func parseTag(_ raw: String) -> (String, [String: String], Bool) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body.removeLast() }
        let nameEnd = body.firstIndex(where: { $0.isWhitespace }) ?? body.endIndex
        let name = String(body[..<nameEnd]).lowercased()
        var attrs: [String: String] = [:]
        let rest = body[nameEnd...]
        let pattern = #"([^\s=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let str = String(rest)
            let ns = str as NSString
            for m in re.matches(in: str, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)).lowercased()
                var val = ""
                for g in 2...4 where m.range(at: g).location != NSNotFound { val = ns.substring(with: m.range(at: g)) }
                attrs[key] = decodeEntities(val)
            }
        }
        return (name, attrs, selfClosing)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                                       "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                       "rdquo": "”", "ldquo": "“", "middot": "·", "times": "×", "rarr": "→", "larr": "←"]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(u) }
                } else if name.hasPrefix("#") {
                    if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(u) }
                } else { rep = named[name] }
                if let r = rep { out += r; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Markdown rendering

private struct Renderer {
    static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre",
                                         "blockquote", "hr", "table", "thead", "tbody", "tr", "section", "article",
                                         "header", "footer", "figure", "del", "ins"]

    /// Children of a pending change that represent the accepted (pre-change) content.
    func accepted(_ chg: HTMLNode) -> [HTMLNode] {
        chg.children.first(where: { $0.tag == "del" })?.children ?? []
    }

    func isChg(_ n: HTMLNode) -> Bool { n.tag == "div" && n.classes.contains("chg") }
    func isChrome(_ n: HTMLNode) -> Bool { n.classes.contains("tools") || n.classes.contains("rb") || n.tag == "script" || n.tag == "style" }

    func hasBlockChild(_ n: HTMLNode) -> Bool {
        n.children.contains { Self.blockTags.contains($0.tag) || isChg($0) }
    }

    mutating func blocks(_ nodes: [HTMLNode], indent: String, separator: String = "\n\n") -> String {
        var parts: [String] = []
        var inlineRun: [HTMLNode] = []
        func flushInline(_ me: inout Renderer) {
            let t = me.inline(inlineRun).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
            inlineRun = []
        }
        for n in nodes {
            if isChrome(n) { continue }
            if n.tag.isEmpty || !(Self.blockTags.contains(n.tag) || isChg(n)) { inlineRun.append(n); continue }
            flushInline(&self)
            let b = block(n, indent: indent)
            if !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(b) }
        }
        flushInline(&self)
        return parts.joined(separator: separator)
    }

    mutating func block(_ n: HTMLNode, indent: String) -> String {
        if isChg(n) { return blocks(accepted(n), indent: indent) }
        switch n.tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(n.tag.last!)) ?? 1
            return String(repeating: "#", count: level) + " " + oneLine(inline(n.children))
        case "p":
            return inline(n.children).trimmingCharacters(in: .whitespacesAndNewlines)
        case "hr":
            return "---"
        case "pre":
            let code = textContent(n).trimmingCharacters(in: .newlines)
            let lang = n.children.first(where: { $0.tag == "code" })?.classes.first(where: { $0.hasPrefix("language-") })?
                .replacingOccurrences(of: "language-", with: "") ?? ""
            return "```\(lang)\n\(code)\n```"
        case "blockquote":
            let inner = blocks(n.children, indent: "")
            return inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case "ul", "ol":
            return list(n, ordered: n.tag == "ol")
        case "li":
            return list(HTMLNode(tag: "ul").adopting([n]), ordered: false)
        case "table":
            return table(n)
        case "del", "ins":
            return "" // stray change halves outside a .chg wrapper: treat as unaccepted / chrome
        default: // div, section, …
            return blocks(n.children, indent: indent)
        }
    }

    mutating func list(_ n: HTMLNode, ordered: Bool) -> String {
        var lines: [String] = []
        var k = Int(n.attrs["start"] ?? "") ?? 1
        var items: [HTMLNode] = []
        for c in n.children {
            if c.tag == "li" { items.append(c) }
            else if isChg(c) { items.append(contentsOf: accepted(c).filter { $0.tag == "li" }) }
        }
        for li in items {
            let marker = ordered ? "\(k). " : "- "
            k += 1
            let pad = String(repeating: " ", count: marker.count)
            let body = hasBlockChild(li) ? blocks(li.children, indent: pad, separator: "\n") : inline(li.children).trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, line) in bodyLines.enumerated() {
                lines.append(idx == 0 ? marker + line : (line.isEmpty ? "" : pad + line))
            }
        }
        return lines.joined(separator: "\n")
    }

    mutating func table(_ n: HTMLNode) -> String {
        var rows: [[String]] = []
        func collect(_ x: HTMLNode) {
            for c in x.children {
                if c.tag == "tr" {
                    rows.append(c.children.filter { $0.tag == "td" || $0.tag == "th" }.map {
                        var r = Renderer()
                        return r.oneLine(r.inline($0.children)).replacingOccurrences(of: "|", with: "\\|")
                    })
                } else if !c.tag.isEmpty { collect(c) }
            }
        }
        collect(n)
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        var out = ["| " + padded[0].joined(separator: " | ") + " |",
                   "|" + Array(repeating: " --- |", count: width).joined()]
        for r in padded.dropFirst() { out.append("| " + r.joined(separator: " | ") + " |") }
        return out.joined(separator: "\n")
    }

    mutating func inline(_ nodes: [HTMLNode]) -> String {
        var out = ""
        for n in nodes {
            if isChrome(n) { continue }
            if n.tag.isEmpty { out += escape(collapse(n.text)); continue }
            switch n.tag {
            case "strong", "b": out += wrap(inline(n.children), "**")
            case "em", "i": out += wrap(inline(n.children), "*")
            case "s", "strike": out += wrap(inline(n.children), "~~")
            case "code": out += codeSpan(textContent(n))
            case "br": out += "  \n"
            case "a":
                let label = inline(n.children)
                if let href = n.attrs["href"], !href.isEmpty { out += "[\(label)](\(href))" } else { out += label }
            case "img":
                out += "![\(n.attrs["alt"] ?? "")](\(n.attrs["src"] ?? ""))"
            case "del": continue  // inline pending deletion markers aren't produced by the editor; skip proposals
            case "ins": continue
            default:
                if isChg(n) { out += inline(accepted(n)) } else { out += inline(n.children) }
            }
        }
        return out
    }

    func wrap(_ s: String, _ m: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return s }
        let lead = s.prefix(while: { $0 == " " }), trail = String(s.reversed().prefix(while: { $0 == " " }))
        return lead + m + t + m + trail
    }

    func codeSpan(_ s: String) -> String {
        let fence = s.contains("`") ? "``" : "`"
        let pad = s.hasPrefix("`") || s.hasSuffix("`") ? " " : ""
        return fence + pad + s + pad + fence
    }

    func textContent(_ n: HTMLNode) -> String {
        n.tag.isEmpty ? n.text : n.children.map(textContent).joined()
    }

    func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "  \n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func escape(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            if "\\*`[]".contains(c) { out.append("\\") }
            else if c == "_" {
                // Intraword underscores (snake_case) are literal in CommonMark; only escape at word edges.
                let before = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                let after = i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1].isNumber)
                if !(before && after) { out.append("\\") }
            }
            out.append(c)
        }
        return out
    }
}

private extension HTMLNode {
    func adopting(_ kids: [HTMLNode]) -> HTMLNode { children = kids; return self }
}

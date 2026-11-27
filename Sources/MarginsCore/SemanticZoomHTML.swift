import Foundation

public enum SemanticZoomHTMLSanitizer {
    public enum Failure: Error, LocalizedError {
        case malformedHTML, unsafeHTML
        public var errorDescription: String? {
            switch self {
            case .malformedHTML: return "The summary did not contain well-formed HTML."
            case .unsafeHTML: return "The summary contained unsupported or unsafe HTML."
            }
        }
    }

    static let allowedTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "li", "blockquote", "pre",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "figure", "figcaption",
        "strong", "em", "b", "i", "s", "u", "code", "a", "img", "br", "hr", "span", "div"
    ]

    public static func sanitize(_ html: String, forPromotion: Bool = false) throws -> String {
        let tokens = try SemanticZoomHTMLParser.parse(html)
        var stack: [String] = []
        var output = ""
        for token in tokens {
            switch token {
            case .text(let text): output += SemanticZoomHTMLParser.escape(text)
            case .open(let name, let attributes, let isVoid):
                guard allowedTags.contains(name) else { throw Failure.unsafeHTML }
                try validate(attributes, tag: name)
                output += renderTag(name, attributes: attributes, forPromotion: forPromotion)
                if !isVoid { stack.append(name) }
            case .close(let name):
                guard stack.last == name else { throw Failure.malformedHTML }
                stack.removeLast()
                output += "</\(name)>"
            }
        }
        guard stack.isEmpty else { throw Failure.malformedHTML }
        return output
    }

    private static func validate(_ attributes: [String: String], tag: String) throws {
        for (name, value) in attributes {
            guard !name.hasPrefix("on"), !["style", "srcdoc", "srcset"].contains(name) else {
                throw Failure.unsafeHTML
            }
            if ["href", "src", "action", "formaction", "poster", "background", "xlink:href"].contains(name) {
                guard (name == "href" && tag == "a") || (name == "src" && tag == "img"),
                      safeURL(value, image: name == "src") else { throw Failure.unsafeHTML }
            }
        }
    }

    static func renderTag(_ name: String, attributes: [String: String], forPromotion: Bool) -> String {
        let attrs = attributes.keys.sorted().compactMap { key -> String? in
            guard let value = attributes[key], allowedAttribute(key, tag: name, promotion: forPromotion) else { return nil }
            if key == "src" || key == "href", !safeURL(value, image: key == "src") { return nil }
            if key == "data-source-block" || key == "data-bid",
               value.range(of: #"^b[0-9]+$"#, options: .regularExpression) == nil { return nil }
            return " \(key)=\"\(SemanticZoomHTMLParser.escape(value))\""
        }.joined()
        return "<\(name)\(attrs)>"
    }

    private static func allowedAttribute(_ name: String, tag: String, promotion: Bool) -> Bool {
        if ["title", "id"].contains(name) { return true }
        if ["data-source-block", "data-bid"].contains(name) { return !promotion }
        if tag == "a" { return name == "href" }
        if tag == "img" { return ["src", "alt", "width", "height"].contains(name) }
        if tag == "td" || tag == "th" { return ["colspan", "rowspan", "scope"].contains(name) }
        if tag == "ol" { return name == "start" }
        return false
    }

    private static func safeURL(_ value: String, image: Bool) -> Bool {
        guard !value.isEmpty, !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        if value.hasPrefix("#") { return !image }
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" { return !(url.host ?? "").isEmpty && url.user == nil }
        if image && scheme == "margins-asset" {
            return url.host == "img" && url.path.range(of: #"^/[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$"#,
                                                     options: .regularExpression) != nil
                && url.query == nil && url.fragment == nil
        }
        return !image && scheme == "mailto" && !url.path.isEmpty
    }
}

enum SemanticZoomHTMLParser {
    enum Token {
        case text(String)
        case open(String, [String: String], Bool)
        case close(String)
    }
    static let voidTags: Set<String> = ["img", "br", "hr", "input", "meta", "link", "area", "base", "embed", "source", "wbr"]

    static func parse(_ html: String) throws -> [Token] {
        var cursor = html.startIndex
        var tokens: [Token] = []
        while cursor < html.endIndex {
            if html[cursor] != "<" {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                tokens.append(.text(decodeEntities(String(html[cursor..<end]))))
                cursor = end
            } else if html[cursor...].hasPrefix("<!--") {
                guard let end = html[cursor...].range(of: "-->") else { throw failure }
                cursor = end.upperBound
            } else {
                let end = try tagEnd(html, after: cursor)
                let inside = String(html[html.index(after: cursor)..<end])
                tokens.append(try parseTag(inside))
                cursor = html.index(after: end)
            }
        }
        return tokens
    }

    private static var failure: SemanticZoomHTMLSanitizer.Failure { .malformedHTML }

    private static func tagEnd(_ html: String, after start: String.Index) throws -> String.Index {
        var cursor = html.index(after: start)
        var quote: Character?
        while cursor < html.endIndex {
            let char = html[cursor]
            if let current = quote {
                if char == current { quote = nil }
            } else if char == "\"" || char == "'" { quote = char
            } else if char == ">" { return cursor
            } else if char == "<" { throw failure }
            cursor = html.index(after: cursor)
        }
        throw failure
    }

    private static func parseTag(_ input: String) throws -> Token {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = content.hasPrefix("/")
        let body = closing ? String(content.dropFirst()) : content
        let name = String(body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
        guard !name.isEmpty else { throw failure }
        let suffix = String(body.dropFirst(name.count))
        if closing {
            guard suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure }
            return .close(name)
        }
        let selfClosing = suffix.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        guard !selfClosing || voidTags.contains(name) else { throw failure }
        let attributeText = selfClosing
            ? " " + String(suffix.trimmingCharacters(in: .whitespacesAndNewlines).dropLast()) : suffix
        return .open(name, try parseAttributes(attributeText), voidTags.contains(name))
    }

    private static func parseAttributes(_ input: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var cursor = input.startIndex
        while cursor < input.endIndex {
            guard input[cursor].isWhitespace else { throw failure }
            skipWhitespace(input, cursor: &cursor)
            if cursor == input.endIndex { break }
            let start = cursor
            while cursor < input.endIndex && attributeCharacter(input[cursor]) { cursor = input.index(after: cursor) }
            guard start != cursor else { throw failure }
            let name = input[start..<cursor].lowercased()
            guard result[name] == nil else { throw failure }
            let afterName = cursor
            skipWhitespace(input, cursor: &cursor)
            if cursor < input.endIndex && input[cursor] == "=" {
                cursor = input.index(after: cursor)
                skipWhitespace(input, cursor: &cursor)
                result[name] = decodeEntities(try attributeValue(input, cursor: &cursor))
            } else {
                result[name] = ""
                cursor = afterName
            }
        }
        return result
    }

    private static func attributeValue(_ input: String, cursor: inout String.Index) throws -> String {
        guard cursor < input.endIndex else { throw failure }
        let quote = input[cursor]
        if quote == "\"" || quote == "'" {
            cursor = input.index(after: cursor)
            let start = cursor
            guard let end = input[cursor...].firstIndex(of: quote) else { throw failure }
            cursor = input.index(after: end)
            return String(input[start..<end])
        }
        let start = cursor
        while cursor < input.endIndex && !input[cursor].isWhitespace {
            guard !["\"", "'", "<", ">", "=", "`"].contains(input[cursor]) else { throw failure }
            cursor = input.index(after: cursor)
        }
        guard cursor > start else { throw failure }
        return String(input[start..<cursor])
    }

    private static func skipWhitespace(_ input: String, cursor: inout String.Index) {
        while cursor < input.endIndex && input[cursor].isWhitespace { cursor = input.index(after: cursor) }
    }

    private static func attributeCharacter(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || ["-", "_", ":"].contains(char))
    }

    static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else { return text }
        var output = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: match.range(at: 1))
            var replacement = named[name]
            if name.hasPrefix("#") {
                let hex = name.hasPrefix("#x")
                if let number = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            }
            if let replacement, let range = Range(match.range, in: output) { output.replaceSubrange(range, with: replacement) }
        }
        return output
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

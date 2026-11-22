import Foundation

/// Author font choices for the document editor and app chrome.
/// Empty string means the system default; sentinel values map to system font designs;
/// any other non-empty string is an installed font family name.
public struct FontPreferences: Codable, Equatable, Sendable {
    public static let systemDefault = ""
    public static let systemSerif = "__system-serif__"
    public static let systemRounded = "__system-rounded__"
    public static let systemMonospace = "__system-mono__"

    public static let defaultCSSStack = #"-apple-system, BlinkMacSystemFont, "Inter", sans-serif"#

    public var documentFont: String
    public var uiFont: String

    public init(documentFont: String = Self.systemDefault, uiFont: String = Self.systemDefault) {
        self.documentFont = documentFont
        self.uiFont = uiFont
    }

    public var documentFontCSS: String { Self.cssFontFamily(for: documentFont) }
    public var uiFontCSS: String { Self.cssFontFamily(for: uiFont) }

    public static func cssFontFamily(for selection: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "", systemDefault:
            return defaultCSSStack
        case systemSerif:
            return "ui-serif, Georgia, serif"
        case systemRounded:
            return "ui-rounded, -apple-system, sans-serif"
        case systemMonospace:
            return "ui-monospace, Menlo, monospace"
        default:
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\", \(defaultCSSStack)"
        }
    }
}

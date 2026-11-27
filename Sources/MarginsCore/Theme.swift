import Foundation

/// The author's explicit System / Light / Dark override.
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The color scheme to render given the current system appearance.
    public func resolve(systemScheme: ThemeColorScheme) -> ThemeColorScheme {
        switch self {
        case .system: return systemScheme
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum ThemeColorScheme: String, Codable, CaseIterable, Sendable {
    case light, dark
}

/// Color tokens for one appearance. Every token is optional in JSON; missing or invalid tokens
/// fall back to the default theme's palette for the same appearance.
public struct ThemePalette: Codable, Equatable, Sendable {
    public static let tokenNames = [
        "railBg", "canvasBg", "sheetBg", "ink", "mutedInk", "line",
        "accent", "accentBg", "accentLine",
        "insBg", "insBorder", "insInk", "delBg", "delBorder", "delInk",
        "threadBg", "threadAccent",
    ]

    /// Editor CSS custom property for each token.
    public static let cssVariableNames: [String: String] = [
        "railBg": "--rail", "canvasBg": "--bg", "sheetBg": "--panel",
        "ink": "--ink", "mutedInk": "--mute", "line": "--line",
        "accent": "--acc", "accentBg": "--accbg", "accentLine": "--accline",
        "insBg": "--ins", "insBorder": "--insb", "insInk": "--insink",
        "delBg": "--del", "delBorder": "--delb", "delInk": "--delink",
        "threadBg": "--thread-bg", "threadAccent": "--thread-acc",
    ]

    public private(set) var tokens: [String: String]

    public init(tokens: [String: String] = [:]) {
        self.tokens = tokens.filter { Self.tokenNames.contains($0.key) }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        self.init(tokens: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tokens)
    }

    public subscript(token: String) -> String? { tokens[token] }

    public var missingTokens: [String] { Self.tokenNames.filter { tokens[$0] == nil } }
    public var isComplete: Bool { missingTokens.isEmpty }
    public var invalidTokens: [String] {
        Self.tokenNames.filter { name in tokens[name].map { !ThemeColor.isValidHex($0) } ?? false }
    }

    /// Drops tokens whose values are not valid hex colors.
    public func droppingInvalidTokens() -> ThemePalette {
        ThemePalette(tokens: tokens.filter { ThemeColor.isValidHex($0.value) })
    }

    /// This palette's tokens layered over `fallback`'s.
    public func filled(from fallback: ThemePalette) -> ThemePalette {
        ThemePalette(tokens: fallback.tokens.merging(droppingInvalidTokens().tokens) { _, own in own })
    }

    public var cssVariables: [String: String] {
        var vars: [String: String] = [:]
        for (token, value) in tokens {
            if let name = Self.cssVariableNames[token] { vars[name] = value }
        }
        return vars
    }
}

public struct ThemeChrome: Codable, Equatable, Sendable {
    public enum SheetStyle: String, Codable, Sendable { case card, seamless }

    public var sheetStyle: SheetStyle
    public var sidebarVibrancy: Bool
    public var cornerRadius: Double

    public init(sheetStyle: SheetStyle = .card, sidebarVibrancy: Bool = false, cornerRadius: Double = 8) {
        self.sheetStyle = sheetStyle
        self.sidebarVibrancy = sidebarVibrancy
        self.cornerRadius = min(max(cornerRadius, 0), 24)
    }

    private enum CodingKeys: String, CodingKey { case sheetStyle, sidebarVibrancy, cornerRadius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let style = (try? c.decodeIfPresent(String.self, forKey: .sheetStyle)).flatMap { $0 }
        self.init(
            sheetStyle: style.flatMap(SheetStyle.init(rawValue:)) ?? .card,
            sidebarVibrancy: (try? c.decodeIfPresent(Bool.self, forKey: .sidebarVibrancy)).flatMap { $0 } ?? false,
            cornerRadius: (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)).flatMap { $0 } ?? 8
        )
    }
}

/// A theme's suggested fonts. Explicit `FontPreferences` choices always win.
public struct ThemeFonts: Codable, Equatable, Sendable {
    public var documentFont: String?
    public var uiFont: String?

    public init(documentFont: String? = nil, uiFont: String? = nil) {
        self.documentFont = documentFont
        self.uiFont = uiFont
    }
}

public struct MarginsTheme: Codable, Equatable, Identifiable, Sendable {
    public static let defaultID = "warm-editorial"

    public var id: String
    public var name: String
    public var author: String?
    public var chrome: ThemeChrome
    public var fonts: ThemeFonts?
    public var light: ThemePalette?
    public var dark: ThemePalette?

    public init(
        id: String, name: String, author: String? = nil, chrome: ThemeChrome = ThemeChrome(),
        fonts: ThemeFonts? = nil, light: ThemePalette? = nil, dark: ThemePalette? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.chrome = chrome
        self.fonts = fonts
        self.light = light
        self.dark = dark
    }

    private enum CodingKeys: String, CodingKey { case id, name, author, chrome, fonts, light, dark }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        name = try c.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        chrome = try c.decodeIfPresent(ThemeChrome.self, forKey: .chrome) ?? ThemeChrome()
        fonts = try c.decodeIfPresent(ThemeFonts.self, forKey: .fonts)
        light = try c.decodeIfPresent(ThemePalette.self, forKey: .light)
        dark = try c.decodeIfPresent(ThemePalette.self, forKey: .dark)
    }

    public var supportedSchemes: [ThemeColorScheme] {
        ThemeColorScheme.allCases.filter { palette(for: $0) != nil }
    }

    /// Picker badge for single-mode themes ("Light only" / "Dark only").
    public var modeBadge: String? {
        switch (light != nil, dark != nil) {
        case (true, false): return "Light only"
        case (false, true): return "Dark only"
        default: return nil
        }
    }

    public func palette(for scheme: ThemeColorScheme) -> ThemePalette? {
        scheme == .light ? light : dark
    }

    /// A complete palette for `scheme`: this theme's tokens over the fallback theme's counterpart.
    public func resolvedPalette(for scheme: ThemeColorScheme, fallback: MarginsTheme = .builtInDefault) -> ThemePalette {
        let base = (fallback.palette(for: scheme) ?? ThemePalette()).filled(from: Self.builtInDefault.palette(for: scheme) ?? ThemePalette())
        guard let own = palette(for: scheme) else { return base }
        return own.filled(from: base)
    }

    public func resolved(for scheme: ThemeColorScheme, fallback: MarginsTheme = .builtInDefault) -> ResolvedTheme {
        ResolvedTheme(id: id, name: name, scheme: scheme, palette: resolvedPalette(for: scheme, fallback: fallback), chrome: chrome, fonts: fonts)
    }
}

/// A theme resolved for one appearance, ready for SwiftUI and the editor.
public struct ResolvedTheme: Equatable, Sendable {
    public var id: String
    public var name: String
    public var scheme: ThemeColorScheme
    public var palette: ThemePalette
    public var chrome: ThemeChrome
    public var fonts: ThemeFonts?

    public func color(_ token: String) -> String {
        palette[token] ?? MarginsTheme.builtInDefault.resolvedPalette(for: scheme)[token] ?? "#000000"
    }

    public var editorPayload: EditorThemePayload {
        EditorThemePayload(
            id: id, colorScheme: scheme.rawValue, sheetStyle: chrome.sheetStyle.rawValue,
            cornerRadius: chrome.cornerRadius, vars: palette.cssVariables
        )
    }

    public static let fallback = MarginsTheme.builtInDefault.resolved(for: .light)
}

/// The JSON object sent to `window.margins.setTheme`.
public struct EditorThemePayload: Codable, Equatable, Sendable {
    public var id: String
    public var colorScheme: String
    public var sheetStyle: String
    public var cornerRadius: Double
    public var vars: [String: String]
}

public extension FontPreferences {
    /// Composes typography: explicit user choice > theme suggestion > system default.
    func effective(with themeFonts: ThemeFonts?) -> FontPreferences {
        FontPreferences(
            documentFont: Self.pick(documentFont, themeFonts?.documentFont),
            uiFont: Self.pick(uiFont, themeFonts?.uiFont)
        )
    }

    enum Source: Equatable, Sendable { case user, theme, system }

    static func source(user: String, theme: String?) -> Source {
        if !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .user }
        if let theme, !theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .theme }
        return .system
    }

    private static func pick(_ user: String, _ theme: String?) -> String {
        switch source(user: user, theme: theme) {
        case .user: return user
        case .theme: return theme ?? systemDefault
        case .system: return systemDefault
        }
    }
}

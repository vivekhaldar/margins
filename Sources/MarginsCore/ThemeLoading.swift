import Foundation

/// Hex color parsing and WCAG contrast helpers.
public enum ThemeColor {
    public struct RGBA: Equatable, Sendable {
        public var red: Double, green: Double, blue: Double, alpha: Double
    }

    /// Accepts `#RGB`, `#RRGGBB`, and `#RRGGBBAA`.
    public static func isValidHex(_ value: String) -> Bool { parse(value) != nil }

    public static func parse(_ value: String) -> RGBA? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        var hex = String(trimmed.dropFirst())
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6 { hex += "FF" }
        guard hex.count == 8, let raw = UInt32(hex, radix: 16) else { return nil }
        func channel(_ shift: UInt32) -> Double { Double((raw >> shift) & 0xFF) / 255 }
        return RGBA(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    public static func relativeLuminance(_ hex: String) -> Double? {
        guard let c = parse(hex) else { return nil }
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    public static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = relativeLuminance(a), let lb = relativeLuminance(b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

public extension MarginsTheme {
    /// The canonical Warm Editorial theme, also bundled as `warm-editorial.json`. Kept in code so
    /// token fallback never depends on bundle resources being present.
    static let builtInDefault = MarginsTheme(
        id: defaultID, name: "Warm Editorial", author: "Margins",
        chrome: ThemeChrome(sheetStyle: .card, sidebarVibrancy: false, cornerRadius: 8),
        fonts: ThemeFonts(documentFont: FontPreferences.systemSerif, uiFont: ""),
        light: ThemePalette(tokens: [
            "railBg": "#F3F0E9", "canvasBg": "#EFECE6", "sheetBg": "#FAF8F4",
            "ink": "#1F1E1C", "mutedInk": "#7A746A", "line": "#E2DCD1",
            "accent": "#C2410C", "accentBg": "#F7E3DA", "accentLine": "#E8B59E",
            "insBg": "#EDF5F0", "insBorder": "#2D6A4F", "insInk": "#1E4D38",
            "delBg": "#F9E6E6", "delBorder": "#B43E3E", "delInk": "#8F2D2D",
            "threadBg": "#F6E8C8", "threadAccent": "#C2410C",
        ]),
        dark: ThemePalette(tokens: [
            "railBg": "#151412", "canvasBg": "#1B1917", "sheetBg": "#22201D",
            "ink": "#EFECE6", "mutedInk": "#9C958B", "line": "#34302B",
            "accent": "#EA7B4A", "accentBg": "#3A241A", "accentLine": "#6B3B24",
            "insBg": "#1A2E24", "insBorder": "#4AA67B", "insInk": "#AEE3C8",
            "delBg": "#361E20", "delBorder": "#D96B6B", "delInk": "#F2B3B3",
            "threadBg": "#332A1B", "threadAccent": "#E5A93B",
        ])
    )
}

public enum ThemeLoadError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missingIdentity
    case noPalettes

    public var description: String {
        switch self {
        case .malformed(let detail): return "malformed theme JSON (\(detail))"
        case .missingIdentity: return "theme is missing a non-empty id or name"
        case .noPalettes: return "theme defines neither a light nor a dark palette"
        }
    }
}

public enum ThemeLoader {
    /// Decodes and validates one theme. Invalid hex tokens are dropped (reported in `warnings`)
    /// so they fall back to the default theme instead of breaking the whole file.
    public static func decode(_ data: Data) throws -> (theme: MarginsTheme, warnings: [String]) {
        var theme: MarginsTheme
        do {
            theme = try JSONDecoder().decode(MarginsTheme.self, from: data)
        } catch {
            throw ThemeLoadError.malformed(String(describing: error).prefix(200).description)
        }
        guard !theme.id.isEmpty, !theme.name.isEmpty else { throw ThemeLoadError.missingIdentity }
        guard theme.light != nil || theme.dark != nil else { throw ThemeLoadError.noPalettes }
        var warnings: [String] = []
        for scheme in ThemeColorScheme.allCases {
            guard let palette = theme.palette(for: scheme) else { continue }
            let invalid = palette.invalidTokens
            guard !invalid.isEmpty else { continue }
            warnings.append("\(scheme.rawValue) tokens with invalid hex ignored: \(invalid.joined(separator: ", "))")
            if scheme == .light { theme.light = palette.droppingInvalidTokens() } else { theme.dark = palette.droppingInvalidTokens() }
        }
        return (theme, warnings)
    }

    /// Loads every `*.json` theme in `directory`, skipping (and logging) unreadable or invalid files.
    public static func loadDirectory(_ directory: URL, log: (String) -> Void = { NSLog("Margins themes: %@", $0) }) -> [MarginsTheme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var themes: [MarginsTheme] = []
        var seen = Set<String>()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension.lowercased() == "json" {
            do {
                let (theme, warnings) = try decode(Data(contentsOf: file))
                warnings.forEach { log("\(file.lastPathComponent): \($0)") }
                guard seen.insert(theme.id).inserted else {
                    log("\(file.lastPathComponent): duplicate theme id '\(theme.id)' ignored")
                    continue
                }
                themes.append(theme)
            } catch {
                log("\(file.lastPathComponent): \(error)")
            }
        }
        return themes
    }
}

public enum ThemeCatalog {
    /// Built-in themes first (default theme leading), then user themes sorted by name.
    /// User themes cannot shadow a built-in id.
    public static func merge(builtIn: [MarginsTheme], user: [MarginsTheme], log: (String) -> Void = { _ in }) -> [MarginsTheme] {
        var builtIns = builtIn
        if !builtIns.contains(where: { $0.id == MarginsTheme.defaultID }) { builtIns.insert(.builtInDefault, at: 0) }
        builtIns.sort { lhs, rhs in
            if lhs.id == MarginsTheme.defaultID { return rhs.id != MarginsTheme.defaultID }
            if rhs.id == MarginsTheme.defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let reserved = Set(builtIns.map(\.id))
        let users = user.filter { theme in
            if reserved.contains(theme.id) { log("user theme '\(theme.id)' shares a built-in id and was ignored"); return false }
            return true
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return builtIns + users
    }

    public static func theme(id: String, in themes: [MarginsTheme]) -> MarginsTheme {
        themes.first { $0.id == id } ?? themes.first { $0.id == MarginsTheme.defaultID } ?? .builtInDefault
    }
}

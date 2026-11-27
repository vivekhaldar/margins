import AppKit
import Foundation
import MarginsCore

extension AppState {
    // MARK: - Themes (#3)

    var activeTheme: MarginsTheme { ThemeStore.shared.theme(id: selectedThemeID) }

    /// The active theme for this window's effective appearance, with missing tokens filled from Warm Editorial.
    var resolvedTheme: ResolvedTheme { activeTheme.resolved(for: effectiveColorScheme) }

    /// Typography actually rendered: explicit user choice > theme suggestion > system default.
    var effectiveFontPreferences: FontPreferences { fontPreferences.effective(with: activeTheme.fonts) }

    func loadThemePreferences() {
        if let id = defaults.string(forKey: "selectedThemeID"), !id.isEmpty, id != selectedThemeID { selectedThemeID = id }
        let mode = defaults.string(forKey: "appearanceMode").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        if mode != appearanceMode { appearanceMode = mode }
        applyAppearance()
    }

    /// Light/Dark overrides go through NSApp so every window, sheet, and the editor follow; System clears the override.
    func applyAppearance() {
        let appearance: NSAppearance?
        switch appearanceMode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if NSApplication.shared.appearance != appearance { NSApplication.shared.appearance = appearance }
    }

    func applyThemeToEditor() {
        objectWillChange.send()
        let payload = resolvedTheme.editorPayload
        Task { await editor.setTheme(payload) }
        applyFontsToEditor()
    }

    /// Pushes everything visual the editor needs after it (re)loads.
    func applyEditorChrome() async {
        await editor.setTheme(resolvedTheme.editorPayload)
        let fonts = effectiveFontPreferences
        await editor.setFonts(document: fonts.documentFontCSS, ui: fonts.uiFontCSS)
        await editor.setZenMode(enabled: zenMode, typewriter: zenTypewriter, paragraphFocus: zenParagraphFocus)
    }
}

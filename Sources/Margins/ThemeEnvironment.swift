import AppKit
import MarginsCore
import SwiftUI

private struct MarginsThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme.fallback
}

extension EnvironmentValues {
    /// The active Margins theme for this window's appearance; SwiftUI chrome reads colors from it.
    var marginsTheme: ResolvedTheme {
        get { self[MarginsThemeKey.self] }
        set { self[MarginsThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: String) {
        guard let rgba = ThemeColor.parse(hex) else {
            self = .primary
            return
        }
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension ResolvedTheme {
    func swiftUIColor(_ token: String) -> Color { Color(hex: color(token)) }
}

/// Native sidebar material behind the instruction pane for themes that opt into vibrancy.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Paints a rail-style surface: the theme's rail color, or sidebar vibrancy tinted by it.
struct ThemedRailBackground: View {
    @Environment(\.marginsTheme) private var theme

    var body: some View {
        if theme.chrome.sidebarVibrancy {
            ZStack {
                SidebarMaterial()
                theme.swiftUIColor("railBg").opacity(0.55)
            }
        } else {
            theme.swiftUIColor("railBg")
        }
    }
}

/// A theme palette token usable anywhere SwiftUI takes a ShapeStyle (fill, foregroundStyle, background).
struct ThemeToken: ShapeStyle {
    let name: String

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.marginsTheme.swiftUIColor(name)
    }
}

extension ShapeStyle where Self == ThemeToken {
    static var themeRail: ThemeToken { ThemeToken(name: "railBg") }
    static var themeSheet: ThemeToken { ThemeToken(name: "sheetBg") }
    static var themeLine: ThemeToken { ThemeToken(name: "line") }
    static var themeAccent: ThemeToken { ThemeToken(name: "accent") }
    static var themeAccentBg: ThemeToken { ThemeToken(name: "accentBg") }
    static var themeThreadBg: ThemeToken { ThemeToken(name: "threadBg") }
    static var themeThreadAccent: ThemeToken { ThemeToken(name: "threadAccent") }
}

import MarginsCore
import SwiftUI

/// Settings › Appearance: appearance mode, theme gallery, and the user themes folder.
struct ThemeSettingsSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            Picker("Appearance", selection: $state.appearanceMode) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(store.themes) { theme in
                ThemeRow(theme: theme, scheme: scheme, isSelected: theme.id == state.activeTheme.id) {
                    state.selectedThemeID = theme.id
                }
            }
            HStack {
                Text("Add your own themes as JSON files; changes load automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Themes Folder") { store.openThemesFolder() }
            }
        } header: {
            Text("Theme")
        }
    }

    private var scheme: ThemeColorScheme { colorScheme == .dark ? .dark : .light }
}

private struct ThemeRow: View {
    let theme: MarginsTheme
    let scheme: ThemeColorScheme
    let isSelected: Bool
    let select: () -> Void

    private static let swatchTokens = ["canvasBg", "sheetBg", "ink", "accent", "insBorder"]

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                swatches
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.name)
                    if let author = theme.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let badge = theme.modeBadge {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(theme.modeBadge.map { "\(theme.name), \($0)" } ?? theme.name)
    }

    private var swatches: some View {
        let palette = theme.resolvedPalette(for: theme.palette(for: scheme) == nil ? (theme.supportedSchemes.first ?? scheme) : scheme)
        return HStack(spacing: 0) {
            ForEach(Self.swatchTokens, id: \.self) { token in
                Color(hex: palette[token] ?? "#000000").frame(width: 14, height: 22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
        .accessibilityHidden(true)
    }
}

/// Explains where a rendered font comes from: the user's pick, the theme's suggestion, or the system.
struct FontSourceNote: View {
    let user: String
    let theme: String?

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var text: String {
        switch FontPreferences.source(user: user, theme: theme) {
        case .user: return "Your choice — overrides the theme’s suggestion."
        case .theme: return "Theme suggestion: \(Self.displayName(theme ?? "")). Pick a font to override it."
        case .system: return "System default."
        }
    }

    private static func displayName(_ selection: String) -> String {
        switch selection {
        case FontPreferences.systemSans: return "System Sans"
        case FontPreferences.systemSerif: return "System Serif"
        case FontPreferences.systemRounded: return "System Rounded"
        case FontPreferences.systemMonospace: return "System Monospace"
        default: return selection
        }
    }
}

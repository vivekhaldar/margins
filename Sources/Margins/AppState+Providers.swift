import Foundation
import MarginsCore

extension AppState {
    // MARK: - Providers

    var activeProvider: ProviderConfig? { providers.first { $0.id == activeProviderID } }
    var enabledProviders: [ProviderConfig] { providers.filter(\.enabled) }

    func setModel(_ model: String, for id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[i].model = model
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, for id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }), providers[i].kind == .codex else { return }
        providers[i].reasoningEffort = effort
    }

    func reloadProviderSettings() {
        guard let data = defaults.data(forKey: "providers"),
              let stored = try? JSONDecoder().decode([ProviderConfig].self, from: data), !stored.isEmpty else { return }
        if providers != stored {
            // Existing runs keep their provider; provider(for:) refreshes changed connections on next use.
            for config in providers where !stored.contains(config) { models[config.id] = nil }
            providers = stored
        }
        let saved = defaults.string(forKey: "activeProvider").flatMap(UUID.init(uuidString:))
        let selected = providers.first { $0.id == saved }?.id ?? providers.first { $0.enabled }?.id ?? providers[0].id
        if selected != activeProviderID { activeProviderID = selected }
    }

    func persistProviders() {
        if let d = try? JSONEncoder().encode(providers) { defaults.set(d, forKey: "providers") }
    }

    func reloadFontPreferences() {
        guard let data = defaults.data(forKey: "fontPreferences"),
              let stored = try? JSONDecoder().decode(FontPreferences.self, from: data) else { return }
        if fontPreferences != stored {
            fontPreferences = stored
        }
    }

    func persistFontPreferences() {
        if let d = try? JSONEncoder().encode(fontPreferences) { defaults.set(d, forKey: "fontPreferences") }
    }

    func applyFontsToEditor() {
        let fonts = effectiveFontPreferences
        let docFont = fonts.documentFontCSS, uiFont = fonts.uiFontCSS
        Task { await editor.setFonts(document: docFont, ui: uiFont) }
    }

    func provider(for config: ProviderConfig) throws -> ModelProvider {
        if let hit = instances[config.id], hit.config.binaryPath == config.binaryPath,
           hit.config.baseURL == config.baseURL, hit.config.kind == config.kind {
            return hit.provider
        }
        instances[config.id]?.provider.shutdown()
        let p = try ProviderFactory.make(config, apiKey: Keychain.get(config.id.uuidString))
        instances[config.id] = (config, p)
        return p
    }

    func invalidate(_ id: UUID) {
        instances[id]?.provider.shutdown()
        instances[id] = nil
        models[id] = nil
    }

    func loadModels(for config: ProviderConfig) async {
        do {
            let list = try await provider(for: config).availableModels()
            models[config.id] = list
        } catch {
            models[config.id] = []
            lastError = error.localizedDescription
        }
    }

    func shutdownProviders() {
        instances.values.forEach { $0.provider.shutdown() }
        instances.removeAll()
    }
}

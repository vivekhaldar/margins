import Foundation
import MarginsCore

extension AppState {
    // MARK: - Providers

    var activeProvider: ProviderConfig? {
        guard case .local(let id) = agentTarget else { return nil }
        return enabledProviders.first { $0.id == id }
    }

    var lastLocalProvider: ProviderConfig? { enabledProviders.first { $0.id == lastLocalProviderID } }
    var enabledProviders: [ProviderConfig] { providers.filter(\.enabled) }

    var isCloudTarget: Bool { activeCloudBackend != nil }
    var activeCloudBackend: CloudBackend? {
        guard case .cloud(let backend) = agentTarget else { return nil }
        return backend
    }

    func agentTargetChanged(from previous: AgentTarget) {
        guard agentTarget != previous else { return }
        switch agentTarget {
        case .local(let id): lastLocalProviderID = id
        case .cloud(let backend): lastCloudBackend = backend
        }
        Task { await editor.setCloudMode(isCloudTarget) }
        if isCloudTarget { refreshCloudContext(forceRepoResolve: false) }
    }

    func toggleLocalCloudTarget() {
        agentTarget = agentTarget.toggled(lastLocal: lastLocalProviderID, lastCloud: lastCloudBackend,
                                          enabledCloud: enabledCloudBackends)
    }

    func reconcileAgentTarget() {
        lastLocalProviderID = AgentTarget.localFallback(preferred: lastLocalProviderID, providers: providers)
            ?? providers.first?.id ?? lastLocalProviderID
        let target = agentTarget.resolvingDisabledCloud(lastLocal: lastLocalProviderID, enabledCloud: enabledCloudBackends)
        let resolved = isCloudTarget ? target : .local(lastLocalProviderID)
        if agentTarget != resolved { agentTarget = resolved }
    }

    static func readEnabledCloudBackends(_ defaults: UserDefaults) -> Set<CloudBackend> {
        guard let stored = defaults.stringArray(forKey: "enabledCloudBackends") else { return Set(CloudBackend.allCases) }
        return Set(stored.compactMap(CloudBackend.init(rawValue:)))
    }

    func setModel(_ model: String, for id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[i].model = model
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, for id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }), providers[i].kind == .codex else { return }
        providers[i].reasoningEffort = effort
    }

    func reloadProviderSettings() {
        // Snapshot all shared settings before applying changes that can write their defaults.
        let enabled = Self.readEnabledCloudBackends(defaults)
        let createPR = defaults.bool(forKey: "cloudDefaultCreatePR")
        let detached = defaults.bool(forKey: "ampDefaultDetached")
        if let data = defaults.data(forKey: "providers"),
           let stored = try? JSONDecoder().decode([ProviderConfig].self, from: data),
           !stored.isEmpty, providers != stored {
            // Existing runs keep their provider; provider(for:) refreshes changed connections on next use.
            for config in providers where !stored.contains(config) { models[config.id] = nil }
            providers = stored
        }
        if enabledCloudBackends != enabled { enabledCloudBackends = enabled }
        if cloudDefaultCreatePR != createPR { cloudDefaultCreatePR = createPR }
        if ampDefaultDetached != detached { ampDefaultDetached = detached }
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

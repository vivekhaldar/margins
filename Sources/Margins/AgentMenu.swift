import MarginsCore
import SwiftUI

struct AgentMenu: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        Group {
            if compact {
                menu
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            } else {
                menu
                    .task(id: state.agentTarget) {
                        if let provider = state.activeProvider, state.models[provider.id] == nil {
                            await state.loadModels(for: provider)
                        }
                    }
            }
        }
        .help(toolsActive ? "Active agent: \(currentLabel) · Tools: \(state.toolPolicy.shortTitle)" : "Active agent: \(currentLabel)")
    }

    private var menu: some View {
        Menu {
            Section("Local") {
                if state.enabledProviders.isEmpty { Text("No enabled providers") }
                ForEach(state.enabledProviders) { provider in
                    Menu(provider.name) { localModels(provider) }
                }
            }
            Section("Cloud") {
                if state.enabledCloudBackends.isEmpty { Text("No enabled cloud agents") }
                ForEach(CloudBackend.allCases.filter(state.enabledCloudBackends.contains), id: \.self) { backend in
                    Toggle(backend.providerName, isOn: Binding(
                        get: { state.agentTarget == .cloud(backend) },
                        set: { _ in state.agentTarget = .cloud(backend) }
                    ))
                }
            }
            if !state.isCloudTarget { localControls }
            Divider()
            SettingsLink { Text("Providers…") }
        } label: {
            if compact {
                Label(currentLabel, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                    .uiFont(.caption)
                    .lineLimit(1)
            } else {
                Label(currentLabel, systemImage: icon).labelStyle(.titleAndIcon)
            }
        }
    }

    @ViewBuilder
    private func localModels(_ provider: ProviderConfig) -> some View {
        let list = state.models[provider.id] ?? []
        if !list.contains(where: { $0.id == "" }) {
            Toggle("Default model", isOn: selection(provider, ""))
        }
        if !provider.model.isEmpty && !list.contains(where: { $0.id == provider.model }) {
            Toggle(provider.model, isOn: selection(provider, provider.model))
        }
        ForEach(list) { model in
            Toggle(model.name, isOn: selection(provider, model.id))
        }
        if list.isEmpty {
            Button("Load models…") { Task { await state.loadModels(for: provider) } }
        }
    }

    @ViewBuilder
    private var localControls: some View {
        if let provider = state.activeProvider, provider.kind == .codex {
            Menu("Reasoning effort: \(provider.reasoningEffort?.title ?? "Default")") {
                Toggle("Default (Codex configuration)", isOn: effortSelection(provider, nil))
                ForEach(ReasoningEffort.allCases) { effort in
                    Toggle(effort.title, isOn: effortSelection(provider, effort))
                }
                Divider()
                Text("Available levels depend on the model and installed Codex version.")
            }
        }
        Section("Agent tools") {
            ForEach(AgentToolPolicy.allCases) { policy in
                Toggle(policy.title, isOn: Binding(get: { state.toolPolicy == policy }, set: { _ in state.toolPolicy = policy }))
            }
            if state.toolPolicy != .off, state.activeProvider?.kind.supportsTools == false {
                Text("This provider has no tools; it answers from the document only.")
            }
            Button(state.projectURL == nil ? "Reveal Agent Workspace" : "Show Project in Finder") { state.revealWorkspace() }
        }
    }

    private var toolsActive: Bool { state.toolPolicy != .off && state.activeProvider?.kind.supportsTools == true }
    private var icon: String { state.isCloudTarget ? "cloud" : (toolsActive ? "wand.and.stars" : "cpu") }

    private func effortSelection(_ provider: ProviderConfig, _ effort: ReasoningEffort?) -> Binding<Bool> {
        Binding(get: { state.activeProvider?.reasoningEffort == effort },
                set: { _ in state.setReasoningEffort(effort, for: provider.id) })
    }

    private func selection(_ provider: ProviderConfig, _ modelID: String) -> Binding<Bool> {
        Binding(
            get: { state.agentTarget == .local(provider.id) && state.activeProvider?.model == modelID },
            set: { _ in
                state.agentTarget = .local(provider.id)
                state.setModel(modelID, for: provider.id)
            }
        )
    }

    private var currentLabel: String {
        if let backend = state.activeCloudBackend { return backend.providerName }
        guard let provider = state.activeProvider else { return "No local provider" }
        var model = state.models[provider.id]?.first { $0.id == provider.model }?.name ?? provider.model
        // "Default (Claude Sonnet 5.5)" → show the concrete model in the toolbar.
        if provider.model.isEmpty, let open = model.firstIndex(of: "("), model.hasSuffix(")") {
            model = String(model[model.index(after: open)..<model.index(before: model.endIndex)])
        }
        let label = "\(provider.name) · \(model.isEmpty ? "Default" : model)"
        if !compact, provider.kind == .codex, let effort = provider.reasoningEffort {
            return "\(label) · \(effort.title)"
        }
        return label
    }
}

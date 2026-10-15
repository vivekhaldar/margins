import MarginsCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var sel = Local<UUID?>(nil)

    var body: some View {
        HSplitView {
            List(selection: $sel.value) {
                ForEach(state.providers) { p in
                    HStack {
                        Image(systemName: p.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(p.enabled ? Color.green : Color.secondary)
                        Text(p.name)
                    }
                    .tag(p.id)
                }
            }
            .frame(minWidth: 200, maxWidth: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        ForEach(ProviderKind.allCases) { k in
                            Button(k.title) {
                                let c = ProviderConfig(kind: k)
                                state.providers.append(c)
                                sel.value = c.id
                            }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button {
                        if let s = sel.value { state.invalidate(s); state.providers.removeAll { $0.id == s } }
                        sel.value = state.providers.first?.id
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(sel.value == nil || state.providers.count <= 1)
                    Spacer()
                }
                .padding(8)
            }
            if let id = sel.value, let i = state.providers.firstIndex(where: { $0.id == id }) {
                ProviderDetail(config: $state.providers[i])
                    .id(id)
                    .frame(minWidth: 380)
            } else {
                Text("Select a provider").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 460)
        .onAppear { sel.value = sel.value ?? state.activeProviderID }
    }
}

private struct ProviderDetail: View {
    @EnvironmentObject var state: AppState
    @Binding var config: ProviderConfig
    @StateObject private var ui = Local(DetailUI())

    struct DetailUI { var apiKey = ""; var testResult: String?; var testing = false }

    private var detected: String {
        guard let b = config.kind.defaultBinary else { return "" }
        return BinaryLocator.locate(b)?.path ?? "not found"
    }

    var body: some View {
        Form {
            Section {
                Text(config.kind.subscriptionNote).font(.callout).foregroundStyle(.secondary)
                TextField("Name", text: $config.name)
                Toggle("Enabled", isOn: $config.enabled)
                Button(state.activeProviderID == config.id ? "Active provider" : "Use this provider") {
                    state.activeProviderID = config.id
                }
                .disabled(state.activeProviderID == config.id || !config.enabled)
            }
            if config.kind.defaultBinary != nil {
                Section("Command-line tool") {
                    LabeledContent("Detected", value: detected).textSelection(.enabled)
                    TextField("Override path", text: $config.binaryPath, prompt: Text("optional"))
                        .onSubmit { state.invalidate(config.id) }
                    Text(signInHint).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Endpoint") {
                    TextField("Base URL", text: $config.baseURL, prompt: Text("https://api.openai.com/v1"))
                        .onSubmit { state.invalidate(config.id) }
                    SecureField("API key", text: $ui.value.apiKey, prompt: Text("stored in Keychain"))
                        .onSubmit(saveKey)
                    Text("Leave the key empty for local servers like Ollama or LM Studio.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Model") {
                TextField("Default model", text: $config.model, prompt: Text("provider default"))
                HStack {
                    Button(ui.value.testing ? "Testing…" : "Test connection & list models") { test() }
                        .disabled(ui.value.testing)
                    if let r = ui.value.testResult { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                if let list = state.models[config.id], !list.isEmpty {
                    Picker("Available", selection: $config.model) {
                        ForEach(list) { Text($0.name).tag($0.id) }
                        if !list.contains(where: { $0.id == config.model }) { Text(config.model.isEmpty ? "Default" : config.model).tag(config.model) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { ui.value.apiKey = Keychain.get(config.id.uuidString) ?? "" }
        .onDisappear(perform: saveKey)
    }

    private var signInHint: String {
        switch config.kind {
        case .copilot: return "Sign in once in Terminal with `copilot` → /login. Margins talks to it over ACP and grants it no tools or file access."
        case .codex: return "Sign in once in Terminal with `codex login` (choose “Sign in with ChatGPT”). Runs read-only and ephemeral."
        case .claudeCode: return "Sign in once in Terminal with `claude` → /login using your Claude Pro/Max account. Runs with all tools disabled."
        case .openAICompatible: return ""
        }
    }

    private func saveKey() {
        guard config.kind == .openAICompatible else { return }
        if ui.value.apiKey != (Keychain.get(config.id.uuidString) ?? "") {
            Keychain.set(ui.value.apiKey, for: config.id.uuidString)
            state.invalidate(config.id)
        }
    }

    private func test() {
        saveKey()
        state.invalidate(config.id)
        ui.value.testing = true
        ui.value.testResult = nil
        Task {
            defer { ui.value.testing = false }
            do {
                let p = try state.provider(for: config)
                let list = try await p.availableModels()
                state.models[config.id] = list
                ui.value.testResult = "OK — \(list.count) model\(list.count == 1 ? "" : "s")"
            } catch {
                ui.value.testResult = error.localizedDescription
            }
        }
    }
}

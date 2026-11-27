import AppKit
import MarginsCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            ProvidersSettingsTab()
                .tabItem { Label("Providers", systemImage: "cpu") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "textformat") }
            NotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            SyncSettingsTab()
                .environmentObject(SyncController.shared)
                .tabItem { Label("Sync", systemImage: "icloud") }
        }
        .frame(width: 720, height: 480)
    }
}

private struct ProvidersSettingsTab: View {
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
        .onAppear { sel.value = sel.value ?? state.activeProviderID }
    }
}

private struct AppearanceSettingsTab: View {
    @EnvironmentObject var state: AppState
    private let installedFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            ThemeSettingsSection()
            Section("Document Font") {
                FontPicker(label: "Font family", selection: $state.fontPreferences.documentFont, families: installedFamilies)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The Quick Brown Fox")
                        .font(UITypography.font(size: 18, scale: 1.0, weight: .semibold, family: state.effectiveFontPreferences.documentFont))
                    Text("Margins keeps your prose readable while tracked changes stay clear and scannable.")
                        .font(UITypography.font(size: 14, scale: 1.0, family: state.effectiveFontPreferences.documentFont))
                        .foregroundStyle(.secondary)
                    FontSourceNote(user: state.fontPreferences.documentFont, theme: state.activeTheme.fonts?.documentFont)
                }
                .padding(.vertical, 4)
            }
            Section("Interface Font") {
                FontPicker(label: "Font family", selection: $state.fontPreferences.uiFont, families: installedFamilies)
                VStack(alignment: .leading, spacing: 4) {
                    Text("INSTRUCTIONS · 2 pending")
                        .font(UITypography.font(.caption, scale: 1.0, weight: .semibold, family: state.effectiveFontPreferences.uiFont))
                        .foregroundStyle(.secondary)
                    Text("Tighten the opening paragraph and add a concrete example.")
                        .font(UITypography.font(.body, scale: 1.0, weight: .medium, family: state.effectiveFontPreferences.uiFont))
                    FontSourceNote(user: state.fontPreferences.uiFont, theme: state.activeTheme.fonts?.uiFont)
                }
                .padding(.vertical, 4)
            }
            Section {
                HStack {
                    Text("Theme and font changes apply immediately to all open windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        state.fontPreferences = FontPreferences()
                    }
                    .disabled(state.fontPreferences == FontPreferences())
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FontPicker: View {
    let label: String
    @Binding var selection: String
    let families: [String]

    private var isCustomUnlisted: Bool {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != FontPreferences.systemSans,
              trimmed != FontPreferences.systemSerif,
              trimmed != FontPreferences.systemRounded,
              trimmed != FontPreferences.systemMonospace else { return false }
        return !families.contains(trimmed)
    }

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Default (Theme or System)").tag(FontPreferences.systemDefault)
            Text("System Sans").tag(FontPreferences.systemSans)
            Text("System Serif").tag(FontPreferences.systemSerif)
            Text("System Rounded").tag(FontPreferences.systemRounded)
            Text("System Monospace").tag(FontPreferences.systemMonospace)
            Divider()
            if isCustomUnlisted {
                Text(selection).tag(selection)
                Divider()
            }
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
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
                if config.kind == .codex {
                    Picker("Reasoning effort", selection: $config.reasoningEffort) {
                        Text("Default (Codex configuration)").tag(nil as ReasoningEffort?)
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.title).tag(Optional(effort))
                        }
                    }
                    Text("Available levels depend on the model and installed Codex version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        case .copilot: return "Sign in once in Terminal with `copilot` → /login. Margins talks to it over ACP; every tool call goes through Margins' permission policy (Agent tools in the model menu), and Research mode asks you before commands or file writes."
        case .codex: return "Sign in once in Terminal with `codex login` (choose “Sign in with ChatGPT”). Runs in Codex's OS sandbox: read-only plus web search in Research mode, workspace-write with network in Full agent mode."
        case .claudeCode: return "Sign in once in Terminal with `claude` → /login using your Claude Pro/Max account. Research mode pre-approves only web and read tools; Full agent adds Bash, Write and Edit."
        case .openAICompatible: return ""  // no agent loop: always answers from the document only
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

private struct NotificationsSettingsTab: View {
    @AppStorage(AgentNotificationPreferences.notifyOnFinishKey) private var notifyOnFinish = true
    @AppStorage(AgentNotificationPreferences.playSoundKey) private var playSound = true
    @AppStorage(AgentNotificationPreferences.onlyWhenInBackgroundKey) private var onlyWhenInBackground = true
    @StateObject private var authStatus = Local<UNAuthorizationStatus>(.notDetermined)

    var body: some View {
        Form {
            Section("Agent Completion") {
                Toggle("Notify when an agent finishes", isOn: $notifyOnFinish)
                    .onChange(of: notifyOnFinish) { _, enabled in
                        guard enabled else { return }
                        AgentNotifications.shared.requestAuthorizationIfNeeded(force: true)
                        Task { authStatus.value = await AgentNotifications.shared.authorizationStatus() }
                    }
                Toggle("Play sound", isOn: $playSound)
                    .disabled(!notifyOnFinish)
                Toggle("Only when document is in background", isOn: $onlyWhenInBackground)
                    .disabled(!notifyOnFinish)
                Text("Notifications fire for instructions, selection threads, tracked-change refinements, and tool approval prompts. Cancelled runs never notify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if authStatus.value == .denied {
                Section("System Permission") {
                    Text("Notifications are currently disabled for Margins in macOS System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Notification Settings…") {
                        AgentNotifications.shared.openSystemNotificationSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            authStatus.value = await AgentNotifications.shared.authorizationStatus()
        }
    }
}

private struct SyncSettingsTab: View {
    @EnvironmentObject var sync: SyncController

    var body: some View {
        Form {
            Section("Google Drive") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(statusDescription)
                            .foregroundStyle(statusColor)
                        if sync.status == .syncing || sync.isSigningIn {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if let last = sync.index.lastSyncedAt {
                    LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                HStack(spacing: 10) {
                    if sync.isConnected {
                        Button("Sync Now") {
                            Task { await sync.syncNow() }
                        }
                        .disabled(sync.status == .syncing)
                        Button("Disconnect", role: .destructive) {
                            sync.disconnectGoogleDrive()
                        }
                    } else if sync.isSigningIn {
                        Button("Cancel Sign-In") {
                            sync.cancelSignIn()
                        }
                    } else {
                        Button("Connect Google Drive…") {
                            sync.connectGoogleDrive()
                        }
                        .disabled(!sync.hasOAuthClient)
                    }
                }
                if let err = sync.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Margins requests only the narrow drive.file scope, giving access solely to its own Margins folder in your Google Drive. Tokens are stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !sync.hasBundledOAuthClient {
                DisclosureGroup("Use a custom Google OAuth client") {
                    TextField("Google OAuth Client ID", text: $sync.oauthConfig.clientID,
                              prompt: Text("1234567890-xxxx.apps.googleusercontent.com"))
                    SecureField("Client Secret (optional)", text: $sync.oauthConfig.clientSecret,
                                prompt: Text("Required by some Google Desktop OAuth clients"))
                    Text("Leave the Client ID empty to use the client included in a distribution build. For a custom client, enable the Google Drive API and choose the Desktop app type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local Library") {
                LabeledContent("Synced folder") {
                    HStack {
                        Text(AppState.documentsFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppState.documentsFolder])
                        }
                    }
                }
                Text("Documents inside ~/Documents/Margins sync automatically. External .margins files opened from elsewhere stay local unless you move them to the Margins Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusDescription: String {
        if sync.isSigningIn { return "Waiting for Google sign-in in browser…" }
        switch sync.status {
        case .disconnected: return "Not connected (local-only)"
        case .synced: return "Connected · Synced"
        case .syncing: return "Syncing…"
        case .offline(let pending): return pending > 0 ? "Offline (\(pending) queued)" : "Offline"
        case .conflict(let count): return "\(count) conflict\(count == 1 ? "" : "s") need attention"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .synced: return .green
        case .conflict, .offline: return .orange
        case .error: return .red
        default: return .secondary
        }
    }
}


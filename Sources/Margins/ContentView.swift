import MarginsCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            IntentPane()
                .interfaceZoom(state.zoom)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            VStack(spacing: 0) {
                if let v = state.previewing { PreviewBanner(version: v).interfaceZoom(state.zoom) }
                EditorView(bridge: state.editor)
            }
            .frame(minWidth: 480)
        }
        .inspector(isPresented: $state.showHistory) {
            HistoryView()
                .interfaceZoom(state.zoom)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .navigationTitle(state.doc.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .alert("Margins", isPresented: Binding(get: { state.lastError != nil }, set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if state.pending.total > 0 { parts.append("\(state.pending.total) pending") }
        if let v = state.doc.versions.last { parts.append("v\(v.number)") }
        parts.append(state.fileURL.deletingPathExtension().lastPathComponent)
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if state.busy { ProgressView().controlSize(.small).interfaceZoom(state.zoom) }
            ProjectMenu().interfaceZoom(state.zoom)
            ProviderMenu().interfaceZoom(state.zoom)
            Button {
                state.showOutline.toggle()
            } label: {
                Label("Outline", systemImage: state.showOutline ? "list.bullet.indent" : "list.bullet")
            }
            .help(state.showOutline ? "Hide outline (⌃⌘O)" : "Show outline (⌃⌘O)")
            .interfaceZoom(state.zoom)
            Button {
                state.showHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Version history (⌥⌘H)")
            .keyboardShortcut("h", modifiers: [.command, .option])
            .interfaceZoom(state.zoom)
        }
    }
}

/// Where the agent works: the author's project folder (so it can write code), or the document's scratch workspace.
struct ProjectMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            if let url = state.projectURL {
                Section(url.path) {
                    Button("Show in Finder") { state.revealWorkspace() }
                    Button("Open in Terminal") { state.openProjectInTerminal() }
                }
                Button("Change Project Folder…") { state.chooseProjectFolder() }
                Button("Stop Using Project Folder") { state.setProjectFolder(nil) }
            } else {
                if let name = state.projectName { Text("“\(name)” is missing") }
                Button("Choose Project Folder…") { state.chooseProjectFolder() }
                Text("Pick a folder (e.g. a code repo) and the agent can write code, run builds and edit files there.")
            }
            Divider()
            Text(hint)
        } label: {
            Label(state.projectName ?? "No project", systemImage: state.projectURL != nil ? "folder.fill" : "folder")
                .labelStyle(.titleAndIcon)
        }
        .help(state.projectURL.map { "Agent works in \($0.path)" } ?? "Choose a project folder for the agent to work in")
    }

    private var hint: String {
        switch state.toolPolicy {
        case .full: return "Agent tools: Full — can change files and run commands."
        case .unrestricted: return "Agent tools: Unrestricted — can change anything on this Mac."
        case .research: return "Agent tools: Research — read-only (Copilot asks before changes)."
        case .off: return "Agent tools: Off — the agent only edits the document."
        }
    }
}

struct ProviderMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            ForEach(state.enabledProviders) { p in
                Section(p.name) {
                    let list = state.models[p.id] ?? []
                    if list.isEmpty {
                        Toggle("Default model", isOn: selection(p, ""))
                        Button("Load models…") { Task { await state.loadModels(for: p) } }
                    } else {
                        ForEach(list) { m in
                            Toggle(m.name, isOn: selection(p, m.id))
                        }
                    }
                }
            }
            Divider()
            if let p = state.activeProvider {
                if p.kind == .codex {
                    Menu("Reasoning effort: \(p.reasoningEffort?.title ?? "Default")") {
                        Toggle("Default (Codex configuration)", isOn: effortSelection(p, nil))
                        ForEach(ReasoningEffort.allCases) { effort in
                            Toggle(effort.title, isOn: effortSelection(p, effort))
                        }
                        Divider()
                        Text("Available levels depend on the model and installed Codex version.")
                    }
                } else {
                    Text("Effort selection is available for Codex.")
                }
            }
            Section("Agent tools") {
                ForEach(AgentToolPolicy.allCases) { p in
                    Toggle(p.title, isOn: Binding(get: { state.toolPolicy == p }, set: { _ in state.toolPolicy = p }))
                }
                if state.toolPolicy != .off, state.activeProvider?.kind.supportsTools == false {
                    Text("This provider has no tools; it answers from the document only.")
                }
                Button(state.projectURL == nil ? "Reveal Agent Workspace" : "Show Project in Finder") { state.revealWorkspace() }
            }
            Divider()
            SettingsLink { Text("Providers…") }
        } label: {
            Label(currentLabel, systemImage: toolsActive ? "wand.and.stars" : "cpu")
                .labelStyle(.titleAndIcon)
        }
        .help(toolsActive ? "Model provider · agent tools: \(state.toolPolicy.shortTitle)" : "Model provider")
        .task(id: state.activeProviderID) {
            if let p = state.activeProvider, state.models[p.id] == nil { await state.loadModels(for: p) }
        }
    }

    private var toolsActive: Bool { state.toolPolicy != .off && state.activeProvider?.kind.supportsTools == true }

    private func effortSelection(_ p: ProviderConfig, _ effort: ReasoningEffort?) -> Binding<Bool> {
        Binding(get: { p.reasoningEffort == effort },
                set: { _ in state.setReasoningEffort(effort, for: p.id) })
    }

    /// Checkmark binding: on when this provider is active and this model is its selected one.
    private func selection(_ p: ProviderConfig, _ modelID: String) -> Binding<Bool> {
        Binding(
            get: { p.id == state.activeProviderID && p.model == modelID },
            set: { _ in
                state.activeProviderID = p.id
                state.setModel(modelID, for: p.id)
            }
        )
    }

    private var currentLabel: String {
        guard let p = state.activeProvider else { return "No provider" }
        var model = state.models[p.id]?.first { $0.id == p.model }?.name ?? p.model
        // "Default (Claude Sonnet 5.5)" → show the concrete model in the toolbar.
        if p.model.isEmpty, let open = model.firstIndex(of: "("), model.hasSuffix(")") {
            model = String(model[model.index(after: open)..<model.index(before: model.endIndex)])
        } else if p.model.isEmpty, model == "Default" || model.hasPrefix("Default ") {
            model = "Default"
        }
        let label = model.isEmpty ? p.name : "\(p.name) · \(model)"
        if p.kind == .codex, let effort = p.reasoningEffort {
            return "\(label) · \(effort.title)"
        }
        return label
    }
}

struct PreviewBanner: View {
    @EnvironmentObject var state: AppState
    let version: Version

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Viewing **v\(version.number)** — \(version.slug)").lineLimit(1)
            Text(version.createdAt, style: .relative).foregroundStyle(.secondary) + Text(" ago").foregroundStyle(.secondary)
            Spacer()
            Button("Return to latest") { state.returnToLatest() }
            Button("Restore this version") { state.restore(version) }
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.18))
        .overlay(Divider(), alignment: .bottom)
    }
}

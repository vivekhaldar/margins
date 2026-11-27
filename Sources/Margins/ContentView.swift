import AppKit
import MarginsCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var sync = SyncController.shared
    @StateObject private var showLibraryPicker = Local(false)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var intentWidth = Local<CGFloat>(340)
    @StateObject private var dragStartWidth = Local<CGFloat?>(nil)

    var body: some View {
        GeometryReader { geo in
            let maxIntent = max(220, geo.size.width - 360)
            let paneWidth = min(max(intentWidth.value, 220), maxIntent)
            HStack(spacing: 0) {
                IntentPane()
                    .environment(\.interfaceZoom, state.zoom)
                    .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
                    .uiFont(.body)
                    .frame(width: paneWidth)
                    .frame(width: state.zenMode ? 0 : paneWidth, alignment: .trailing)
                    .opacity(state.zenMode ? 0 : 1)
                    .clipped()
                    .disabled(state.zenMode)
                    .allowsHitTesting(!state.zenMode)
                    .accessibilityHidden(state.zenMode)
                if !state.zenMode {
                    SplitDivider(width: $intentWidth.value, dragStart: $dragStartWidth.value, range: 220...maxIntent)
                        .transition(.opacity)
                }
                editorColumn
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.zenMode)
        }
        .sheet(isPresented: $showLibraryPicker.value) {
            LibraryPickerView(sync: sync, onDismiss: { showLibraryPicker.value = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .marginsOpenLibraryPicker)) { _ in
            if DocumentWindows.shared.keyState === state {
                showLibraryPicker.value = true
            }
        }
        .inspector(isPresented: $state.showHistory) {
            HistoryView()
                .environment(\.interfaceZoom, state.zoom)
                .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
                .uiFont(.body)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 720)
        }
        .navigationTitle(state.doc.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .toolbar(state.zenMode ? .hidden : .visible, for: .windowToolbar)
        .environment(\.marginsTheme, state.resolvedTheme)
        .onAppear { state.effectiveColorScheme = colorScheme == .dark ? .dark : .light }
        .onChange(of: colorScheme) { _, scheme in state.effectiveColorScheme = scheme == .dark ? .dark : .light }
        .alert("Margins", isPresented: Binding(get: { state.lastError != nil }, set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if sync.showOnboarding {
                SyncOnboardingBanner(sync: sync)
            }
            if let entry = sync.entry(for: state.doc.id),
               entry.state == .conflict,
               let conflictName = entry.conflictFilename {
                ConflictBanner(
                    conflictFilename: conflictName,
                    onOpenConflict: {
                        let url = AppState.documentsFolder.appendingPathComponent(conflictName)
                        DocumentWindows.shared.open(url)
                    },
                    onDismiss: {
                        sync.clearConflict(for: state.doc.id)
                    }
                )
            }
            if let v = state.previewing {
                PreviewBanner(version: v)
                    .environment(\.interfaceZoom, state.zoom)
                    .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
            }
            EditorView(bridge: state.editor)
        }
        .frame(minWidth: 360, maxWidth: .infinity)
        .layoutPriority(1)
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
            SyncStatusPill(sync: sync).interfaceZoom(state.zoom)
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
                state.toggleZenMode()
            } label: {
                Label("Zen Mode", systemImage: "rectangle.center.inset.filled")
            }
            .help("Zen Mode (⇧⌘F)")
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
            let recent = state.recentProjectFolders
            if !recent.isEmpty {
                Section("Recent Projects") {
                    ForEach(recent, id: \.self) { url in
                        Button {
                            state.selectProjectFolder(url)
                        } label: {
                            Label(ProjectFolderStore.displayLabel(for: url, among: recent), systemImage: "folder")
                        }
                    }
                    Button("Clear Recent Projects") { state.clearRecentProjectFolders() }
                }
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
    @Environment(\.marginsTheme) private var theme
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
        .uiFont(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.swiftUIColor("threadBg"))
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct SplitDivider: View {
    @Binding var width: CGFloat
    @Binding var dragStart: CGFloat?
    let range: ClosedRange<CGFloat>
    @Environment(\.marginsTheme) private var theme
    @StateObject private var hovering = Local(false)

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.swiftUIColor("line"))
                .frame(width: 1)
            Color.clear
                .frame(width: 7)
                .contentShape(Rectangle())
        }
        .frame(width: 1)
        .onHover { inside in
            guard inside != hovering.value else { return }
            hovering.value = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering.value {
                hovering.value = false
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let proposed = (dragStart ?? width) + value.translation.width
                    width = min(max(proposed, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

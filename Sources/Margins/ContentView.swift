import MarginsCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            IntentPane()
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            VStack(spacing: 0) {
                if let v = state.previewing { PreviewBanner(version: v) }
                EditorView(bridge: state.editor)
            }
            .frame(minWidth: 480)
        }
        .inspector(isPresented: $state.showHistory) {
            HistoryView()
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
            if state.busy { ProgressView().controlSize(.small) }
            ProviderMenu()
            Button {
                state.showHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Version history (⌥⌘H)")
            .keyboardShortcut("h", modifiers: [.command, .option])
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
                        Button(p.id == state.activeProviderID ? "✓ Default model" : "Default model") {
                            state.activeProviderID = p.id
                        }
                        Button("Load models…") { Task { await state.loadModels(for: p) } }
                    } else {
                        ForEach(list) { m in
                            Button {
                                state.activeProviderID = p.id
                                state.setModel(m.id, for: p.id)
                            } label: {
                                let on = p.id == state.activeProviderID && p.model == m.id
                                Text((on ? "✓ " : "") + m.name)
                            }
                        }
                    }
                }
            }
            Divider()
            SettingsLink { Text("Providers…") }
        } label: {
            Label(currentLabel, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .help("Model provider")
        .task(id: state.activeProviderID) {
            if let p = state.activeProvider, state.models[p.id] == nil { await state.loadModels(for: p) }
        }
    }

    private var currentLabel: String {
        guard let p = state.activeProvider else { return "No provider" }
        let model = state.models[p.id]?.first { $0.id == p.model }?.name ?? p.model
        return model.isEmpty ? p.name : "\(p.name) · \(model)"
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

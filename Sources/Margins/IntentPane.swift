import MarginsCore
import SwiftUI

/// Left pane: the log of instructions (not a chat — each card is an *intent* whose result
/// lives in the document) plus the composer.
struct IntentPane: View {
    @EnvironmentObject var state: AppState
    @StateObject private var draftBox = Local("")
    @FocusState private var composerFocused: Bool

    private let suggestions = ["Tighten the prose", "Add an example", "Make it more concrete", "Add a summary at the top"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("INSTRUCTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if state.pending.total > 0 {
                    Text("\(state.pending.total) pending")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if state.doc.intents.isEmpty { EmptyIntro() }
                        ForEach(state.doc.intents) { intent in
                            if intent.kind == .edit {
                                EditRow(intent: intent)
                            } else {
                                IntentCard(intent: intent).id(intent.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: state.doc.intents.count) {
                    if let last = state.doc.intents.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.doc.intents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { draftBox.value = s; send() }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(.tertiary))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draftBox.value)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .frame(minHeight: 64, maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
                if draftBox.value.isEmpty {
                    Text(state.doc.intents.isEmpty ? "What do you want to write? e.g. “A design doc for rate limiting our public API”"
                                                   : "Refine the document… (select text first to scope it)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(composerFocused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25)))
            HStack {
                Text("↩ send · ⇧↩ newline").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draftBox.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .onAppear { composerFocused = true }
    }

    private func send() {
        state.submit(draftBox.value)
        draftBox.value = ""
    }
}

private struct EmptyIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Write by refining, not chatting.").font(.headline)
            Text("Describe the document you want. The agent drafts it on the right. Every instruction after that shows up as tracked changes you can accept, reject, or refine — and you can always edit the text yourself.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
    }
}

private struct EditRow: View {
    let intent: Intent
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").foregroundStyle(.green)
            Text(intent.text).lineLimit(1)
            Spacer()
            Text(intent.createdAt, style: .time)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

struct IntentCard: View {
    @EnvironmentObject var state: AppState
    let intent: Intent
    @StateObject private var hoverBox = Local(false)

    private var pendingCount: Int { state.pending.byStep[intent.step] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(intent.text).font(.body.weight(.medium)).textSelection(.enabled)
            status
            if intent.steps != nil || state.liveThought[intent.step] != nil {
                AgentActivity(intent: intent)
            }
            if let ask = state.permissionAsks[intent.step] {
                PermissionPrompt(ask: ask)
            }
            if !intent.summary.isEmpty {
                Text(intent.summary).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(intent.notes, id: \.self) { n in
                Label { Text(n) } icon: { Image(systemName: "info.circle") }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .overlay(Rectangle().fill(Color.accentColor.opacity(0.4)).frame(width: 2), alignment: .leading)
            }
            ForEach(Array(intent.refinements.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 4) {
                    Text("↳ 💬").foregroundStyle(Color.accentColor)
                    Text(r.text).italic()
                }
                .font(.caption)
            }
            if pendingCount > 0 {
                HStack(spacing: 6) {
                    Button("Accept these") { state.review(step: intent.step, accept: true) }
                    Button("Reject") { state.review(step: intent.step, accept: false) }
                    Spacer()
                    Button { state.reveal(step: intent.step) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless).help("Show in document")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hoverBox.value && pendingCount > 0 ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2)))
        .onHover { h in
            hoverBox.value = h
            if pendingCount > 0 || !h { state.hover(step: h ? intent.step : nil) }
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            switch intent.status {
            case .working:
                ProgressView().controlSize(.mini)
                Text(state.permissionAsks[intent.step] != nil ? "Waiting for you…" : "Working…")
            case .pending:
                chip("\(pendingCount) pending", .orange)
            case .reviewed:
                chip("reviewed", .green)
            case .done:
                chip("applied", .green)
            case .failed:
                chip("failed", .red)
            }
            if !intent.provider.isEmpty { Text(intent.provider).lineLimit(1) }
            if intent.status == .working {
                Spacer()
                Button("Stop") { state.stop(step: intent.step) }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Stop the agent")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        if let e = intent.error {
            Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func chip(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.15)))
            .foregroundStyle(c)
    }
}

/// The agent's tool calls for one instruction: live while working, collapsed afterwards.
private struct AgentActivity: View {
    @EnvironmentObject var state: AppState
    let intent: Intent
    @StateObject private var expanded = Local(false)

    private var steps: [AgentStep] { intent.steps ?? [] }
    private var working: Bool { intent.status == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if working {
                ForEach(steps.suffix(6)) { StepRow(step: $0) }
                if steps.count > 6 {
                    Text("+ \(steps.count - 6) earlier").font(.caption2).foregroundStyle(.tertiary)
                }
                if let t = state.liveThought[intent.step]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    Text(t).font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !steps.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.value.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded.value ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                        Text(summary)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded.value { ForEach(steps) { StepRow(step: $0) } }
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let n = steps.count
        let denied = steps.filter { $0.status == .denied }.count
        var s = "Used \(n) tool\(n == 1 ? "" : "s")"
        let kinds = Set(steps.map(\.kind))
        var what: [String] = []
        if kinds.contains(.fetch) || kinds.contains(.search) { what.append("web") }
        if kinds.contains(.execute) { what.append("shell") }
        if kinds.contains(.read) || kinds.contains(.edit) { what.append("files") }
        if !what.isEmpty { s += " · " + what.joined(separator: ", ") }
        if denied > 0 { s += " · \(denied) denied" }
        return s
    }
}

private struct StepRow: View {
    let step: AgentStep
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Group {
                switch step.status {
                case .running: ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                case .done: Image(systemName: step.kind.symbol).foregroundStyle(.secondary)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .denied: Image(systemName: "hand.raised").foregroundStyle(.red)
                }
            }
            .font(.system(size: 9)).frame(width: 12)
            Text(label).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(step.status == .denied ? .tertiary : .secondary)
                .strikethrough(step.status == .denied)
        }
        .font(.caption)
        .help(step.detail.isEmpty ? step.title : step.detail)
    }

    private var label: AttributedString {
        let firstLine = step.detail.split(separator: "\n").first.map(String.init) ?? ""
        var a = AttributedString(step.title.isEmpty ? step.kind.rawValue.capitalized : step.title)
        if !firstLine.isEmpty, !step.title.contains(firstLine) {
            var d = AttributedString("  " + firstLine)
            d.font = .system(.caption, design: .monospaced)
            a += d
        }
        return a
    }
}

/// Inline approval for a side-effecting tool call (Research mode).
private struct PermissionPrompt: View {
    @EnvironmentObject var state: AppState
    let ask: PermissionAsk

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ask.request.title, systemImage: ask.request.kind.symbol)
                .font(.caption.weight(.semibold))
            if !ask.request.detail.isEmpty {
                ScrollView {
                    Text(ask.request.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            HStack(spacing: 6) {
                Button("Allow") { state.answerPermission(step: ask.step, .allowOnce) }
                Button("Allow all") { state.answerPermission(step: ask.step, .allowAlways) }
                    .help("Allow this and similar actions for the rest of this instruction")
                Button("Deny") { state.answerPermission(step: ask.step, .deny) }
            }
            .controlSize(.small)
            Text("The agent works in this document's workspace folder.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.45)))
    }
}

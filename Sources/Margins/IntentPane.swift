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
                Text("Working…")
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

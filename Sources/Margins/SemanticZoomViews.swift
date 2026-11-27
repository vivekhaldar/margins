import MarginsCore
import SwiftUI

struct SemanticZoomControl: View {
    @EnvironmentObject var state: AppState
    @StateObject private var showingPopover = Local(false)
    @StateObject private var preview = Local(100.0)
    @StateObject private var editing = Local(false)

    private var disabled: Bool {
        state.busy || (state.semanticZoomStop.rawValue == 100
            && (!state.canSemanticZoom || state.semanticZoomSourceWordCount < SemanticZoomStop.minimumWordCount))
    }

    var body: some View {
        Button {
            preview.value = Double(state.semanticZoomStop.rawValue)
            showingPopover.value.toggle()
        } label: {
            Text("Size \(state.semanticZoomStop.rawValue)%")
                .monospacedDigit()
        }
        .disabled(disabled)
        .help(state.semanticZoomSourceWordCount < SemanticZoomStop.minimumWordCount
            && state.semanticZoomStop.rawValue == 100
            ? "Semantic zoom needs at least 200 words; this document has \(state.semanticZoomSourceWordCount)."
            : "Semantic document size (⌥⌘[ / ⌥⌘] / ⌥⌘0)")
        .popover(isPresented: $showingPopover.value, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Document size")
                    Spacer()
                    Text("\(Int(preview.value.rounded()))% · \(SemanticZoomStop.nearest(to: preview.value).label)")
                        .monospacedDigit()
                }
                Slider(value: $preview.value, in: 10...100) { isEditing in
                    editing.value = isEditing
                    if !isEditing { commitPreview() }
                }
                .accessibilityLabel("Document size")
                .accessibilityValue("\(Int(preview.value.rounded())) percent")
                .disabled(disabled)
                HStack(spacing: 6) {
                    ForEach(SemanticZoomStop.allCases.reversed(), id: \.rawValue) { stop in
                        let selected = state.semanticZoomStop == stop
                        Button("\(stop.rawValue)%") {
                            preview.value = Double(stop.rawValue)
                            if stop != state.semanticZoomStop { state.setSemanticZoom(stop) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(selected ? .accentColor : nil)
                        .fontWeight(selected ? .semibold : .regular)
                        .monospacedDigit()
                        .disabled(disabled)
                        .help("\(stop.rawValue)% · \(stop.label)")
                    }
                }
                Text("Drag or click a stop (10%–100%). Summaries are read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 300)
        }
        .onChange(of: state.semanticZoomStop.rawValue) { _, value in
            if !editing.value { preview.value = Double(value) }
        }
        .onChange(of: preview.value) { _, _ in
            // Keyboard and accessibility slider changes have no drag-release event.
            if !editing.value && showingPopover.value { commitPreview() }
        }
    }

    private func commitPreview() {
        guard !disabled else { return }
        let stop = SemanticZoomStop.nearest(to: preview.value)
        preview.value = Double(stop.rawValue)
        if stop != state.semanticZoomStop { state.setSemanticZoom(stop) }
    }
}

struct SemanticZoomBanner: View {
    @EnvironmentObject var state: AppState
    @Environment(\.marginsTheme) private var theme

    private var canUseSummary: Bool {
        state.semanticZoomHTML != nil && !state.semanticZoomLoading && state.semanticZoomError == nil && !state.busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "text.badge.minus")
                Text("\(state.semanticZoomStop.rawValue)% · Read-only summary")
                    .fontWeight(.medium)
                Spacer()
                Text("\(state.semanticZoomWordCount) of \(state.semanticZoomSourceWordCount) words")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Full document") { state.setSemanticZoom(.full) }
                    .help("Return to the full document (⌥⌘0)")
            }
            if state.semanticZoomLoading {
                loadingStatus
            } else if let error = state.semanticZoomError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("Try again") { state.regenerateSemanticZoom() }.disabled(state.busy)
                    Spacer()
                }
            } else {
                summaryActions
            }
        }
        .uiFont(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.swiftUIColor("threadBg"))
        .overlay(Divider(), alignment: .bottom)
    }

    private var loadingStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating summary…")
                if let started = state.semanticZoomStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                        Text("\(seconds)s elapsed").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") { state.cancelSemanticZoom() }
            }
            if let status = state.semanticZoomStatus {
                Text(status)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var summaryActions: some View {
        HStack(spacing: 10) {
            Menu("Copy") {
                Button("Copy Markdown") { state.copySemanticZoomMarkdown() }
                Button("Copy Rich Text") { state.copySemanticZoomRichText() }
            }
            .disabled(!canUseSummary)
            Menu("Use summary") {
                Button("Replace current document") { state.replaceWithSemanticZoom() }
                Button("Duplicate as new document") { state.duplicateSemanticZoom() }
            }
            .disabled(!canUseSummary)
            Spacer()
            Button("Regenerate") { state.regenerateSemanticZoom() }
                .disabled(state.busy || !state.canSemanticZoom)
        }
    }
}

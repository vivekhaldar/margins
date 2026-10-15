import MarginsCore
import SwiftUI

/// How the document evolved: every agent change, your edits, and review bursts — with a slug, not just a number.
struct HistoryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.headline)
                Text("\(state.doc.versions.count) versions").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if state.doc.versions.isEmpty {
                Text("Versions appear here as the document changes.")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.doc.versions.reversed()) { v in
                            VersionRow(version: v, isLatest: v.id == state.doc.versions.last?.id,
                                       isViewing: state.previewing?.id == v.id ||
                                           (state.previewing == nil && v.id == state.doc.versions.last?.id))
                                .contentShape(Rectangle())
                                .onTapGesture { state.preview(v) }
                                .contextMenu {
                                    Button("Preview") { state.preview(v) }
                                    Button("Restore this version") { state.restore(v) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

private struct VersionRow: View {
    let version: Version
    let isLatest: Bool
    let isViewing: Bool

    private var color: Color {
        switch version.author {
        case .agent: return .indigo
        case .you: return .green
        case .review: return .orange
        }
    }

    private var who: String {
        switch version.author {
        case .agent: return "Agent"
        case .you: return "You"
        case .review: return "You · review"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().strokeBorder(color, lineWidth: 2).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(version.number)").font(.caption.monospaced().weight(.semibold))
                    Text(who).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
                    Text(version.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if isLatest { Text("current").font(.caption2.weight(.semibold)) }
                }
                Text(version.slug).font(.callout.weight(.medium))
                if !version.detail.isEmpty {
                    Text(version.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(isViewing ? Color.accentColor.opacity(0.12) : .clear))
    }
}

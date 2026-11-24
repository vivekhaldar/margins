import AppKit
import MarginsCore
import SwiftUI

/// In-app library picker (`⌘O` when Google Drive sync is connected) backed by `sync-index.json`.
/// Lists documents by recency with instant search, sync badges, on-demand cloud download,
/// and a one-click "Open from Disk…" fallback.
struct LibraryPickerView: View {
    @ObservedObject var sync: SyncController
    let onDismiss: () -> Void
    @StateObject private var query = Local("")
    @StateObject private var downloadingID = Local<UUID?>(nil)

    private var filtered: [SyncEntry] {
        let q = query.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = sync.index.sortedByRecency
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.filename.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Margins Library…", text: $query.value)
                    .textFieldStyle(.plain)
                if !query.value.isEmpty {
                    Button {
                        query.value = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text(query.value.isEmpty ? "No documents in Margins Library yet" : "No matching documents")
                        .foregroundStyle(.secondary)
                    if query.value.isEmpty {
                        Text("Documents saved in ~/Documents/Margins appear here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text("\(entry.filename) · \(entry.modifiedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if downloadingID.value == entry.docID {
                                ProgressView().controlSize(.small)
                            } else {
                                SyncEntryBadge(state: entry.state)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("Open from Disk… (⇧⌘O)") {
                    onDismiss()
                    DispatchQueue.main.async { DocumentWindows.shared.showOpenPanel() }
                }
                Spacer()
                Button("Sync Now") {
                    Task { await sync.syncNow() }
                }
                .disabled(!sync.isConnected || sync.status == .syncing)
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 520, height: 420)
        .onAppear { sync.refreshLocalLibrary() }
    }

    private func open(_ entry: SyncEntry) {
        if entry.state == .cloudOnly {
            downloadingID.value = entry.docID
            Task {
                await sync.openFromLibrary(entry)
                downloadingID.value = nil
                onDismiss()
            }
        } else {
            onDismiss()
            Task { await sync.openFromLibrary(entry) }
        }
    }
}

private struct SyncEntryBadge: View {
    let state: DocumentSyncState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }

    private var label: String {
        switch state {
        case .synced: return "Synced"
        case .pendingUpload: return "Pending"
        case .downloading: return "Downloading"
        case .cloudOnly: return "Cloud-only"
        case .conflict: return "Conflict"
        }
    }

    private var icon: String {
        switch state {
        case .synced: return "checkmark.icloud"
        case .pendingUpload: return "icloud.and.arrow.up"
        case .downloading: return "icloud.and.arrow.down"
        case .cloudOnly: return "icloud"
        case .conflict: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch state {
        case .synced: return .green
        case .pendingUpload: return .secondary
        case .downloading, .cloudOnly: return .blue
        case .conflict: return .orange
        }
    }
}

/// Subtle toolbar sync state pill with popover for last-synced time, Sync Now, and Move to Library.
struct SyncStatusPill: View {
    @ObservedObject var sync: SyncController
    @EnvironmentObject var state: AppState
    @StateObject private var showPopover = Local(false)

    private var isExternalFile: Bool {
        !sync.isInSyncedLibrary(state.fileURL)
    }

    private var docEntry: SyncEntry? {
        sync.entry(for: state.doc.id)
    }

    private var pillLabel: String {
        if !sync.isConnected { return "Local" }
        if isExternalFile { return "Local" }
        if docEntry?.state == .conflict { return "Conflict" }
        return sync.status.label
    }

    private var pillIcon: String {
        if !sync.isConnected || isExternalFile { return "laptopcomputer" }
        if docEntry?.state == .conflict { return "exclamationmark.triangle.fill" }
        switch sync.status {
        case .disconnected: return "laptopcomputer"
        case .synced: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "icloud.slash"
        case .conflict: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.icloud"
        }
    }

    private var pillColor: Color {
        if !sync.isConnected || isExternalFile { return .secondary }
        if docEntry?.state == .conflict { return .orange }
        switch sync.status {
        case .synced: return .secondary
        case .syncing: return .accentColor
        case .offline, .conflict: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    var body: some View {
        Button {
            showPopover.value.toggle()
        } label: {
            Label(pillLabel, systemImage: pillIcon)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(pillColor)
        }
        .help(sync.isConnected ? "Google Drive sync status" : "Local-only mode — configure Google Drive in Settings")
        .popover(isPresented: $showPopover.value, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: pillIcon).foregroundStyle(pillColor)
                    Text(sync.isConnected ? "Google Drive Sync" : "Local-Only Mode")
                        .fontWeight(.semibold)
                    Spacer()
                }
                if sync.isConnected {
                    if isExternalFile {
                        Text("This file is outside ~/Documents/Margins and stays local-only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Move to Margins Library") {
                            showPopover.value = false
                            sync.moveToSyncedLibrary(state: state)
                        }
                    } else if let last = sync.index.lastSyncedAt {
                        Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ready to sync with Google Drive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let err = sync.lastError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                    Divider()
                    HStack {
                        Button("Sync Now") {
                            Task { await sync.syncNow() }
                        }
                        .disabled(sync.status == .syncing)
                        Spacer()
                        SettingsLink { Text("Sync Settings…") }
                    }
                } else {
                    Text("Connect Google Drive to sync documents, history, and threads across Macs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        SettingsLink { Text("Set Up Google Drive…") }
                        Spacer()
                    }
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

/// Banner shown at the top of a document window when V1 conflict resolution saved a divergent local copy.
struct ConflictBanner: View {
    let conflictFilename: String
    let onOpenConflict: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Sync conflict: your local edits were saved to “\(conflictFilename)” so nothing was lost.")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Open Conflict Copy", action: onOpenConflict)
                .controlSize(.small)
            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// Optional first-run banner offering Google Drive sync or keeping documents local.
struct SyncOnboardingBanner: View {
    @ObservedObject var sync: SyncController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud")
                .foregroundStyle(Color.accentColor)
            Text("Sync your Margins documents across Macs with Google Drive, or keep everything local.")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            SettingsLink {
                Text("Sync with Google Drive…")
            }
            .controlSize(.small)
            .simultaneousGesture(TapGesture().onEnded { sync.dismissOnboarding() })
            Button("Keep Local") {
                sync.dismissOnboarding()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }
}

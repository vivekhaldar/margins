import MarginsCore
import SwiftUI

/// Compact Local / Cloud target pill rendered in the IntentPane composer.
struct ComposerTargetPill: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            pillButton(.local, title: "Local", icon: "laptopcomputer")
            pillButton(.cloud, title: "Cloud", icon: "cloud")
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func pillButton(_ target: ComposerTarget, title: String, icon: String) -> some View {
        let selected = state.composerTarget == target
        return Button {
            state.composerTarget = target
            if target == .cloud {
                state.refreshCloudContext(forceRepoResolve: false)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .uiFont(.caption, weight: selected ? .semibold : .regular)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Inline cloud target options shown when the composer is in Cloud mode.
struct CloudComposerOptions: View {
    @EnvironmentObject var state: AppState
    @Environment(\.interfaceZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("owner/repo", text: $state.cloudRepo)
                    .textFieldStyle(.roundedBorder)
                    .uiFont(.caption, design: .monospaced)
                    .help("GitHub repository (owner/repo)")
                TextField("main", text: $state.cloudBaseRef)
                    .textFieldStyle(.roundedBorder)
                    .uiFont(.caption, design: .monospaced)
                    .frame(maxWidth: 110 * zoom)
                    .help("Base branch on GitHub")
            }

            HStack(spacing: 8) {
                Toggle("Open PR", isOn: $state.cloudCreatePR)
                    .toggleStyle(.switch)
                    .controlSize(UITypography.controlSize(for: zoom, compact: true))
                    .uiFont(.caption)
                Spacer()
                Text(state.cloudCreatePR ? "Creates a pull request" : "Read-only instructions")
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if state.cloudDirtyFilesCount > 0 {
                let count = state.cloudDirtyFilesCount
                Label(
                    "\(count) uncommitted local \(count == 1 ? "change" : "changes") — cloud runs against pushed \(state.cloudBaseRef.isEmpty ? "base branch" : state.cloudBaseRef) on GitHub.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .uiFont(.caption2)
                .foregroundStyle(.orange)
            }

            authGuidance
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder
    private var authGuidance: some View {
        switch state.cloudAuthStatus {
        case .missingBinary:
            Label(
                "GitHub CLI (`gh`) not found. Install it (`brew install gh`) and run `gh auth login`.",
                systemImage: "terminal"
            )
            .uiFont(.caption2)
            .foregroundStyle(.red)
        case .notAuthenticated:
            HStack(spacing: 6) {
                Label("Not logged in to GitHub CLI. Run `gh auth login` in Terminal.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .uiFont(.caption2)
                    .foregroundStyle(.red)
                Spacer()
                Button("Recheck") { state.refreshCloudContext(forceRepoResolve: false) }
                    .buttonStyle(.borderless)
                    .uiFont(.caption2)
            }
        case .authenticated, .none:
            EmptyView()
        }
    }
}

/// Cloud-specific status pill, links, attention callout, log viewer, and Insert action for IntentCard.
struct CloudTaskCardSection: View {
    @EnvironmentObject var state: AppState
    @Environment(\.interfaceZoom) private var zoom
    let intent: Intent
    let task: CloudTaskRef
    @StateObject private var logExpanded = Local(false)

    private var taskState: CloudTaskState { CloudTaskState(rawState: task.cloudState) }
    private var logText: String { state.cloudLogs[intent.id] ?? "" }
    private var isStreaming: Bool { state.cloudStreamingIntentIDs.contains(intent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if taskState.needsAttention {
                attentionBanner
            }
            linksAndActionsRow
            if task.sessionID != nil || !logText.isEmpty {
                logViewer
            }
        }
        .onDisappear {
            if logExpanded.value {
                state.setCloudLogExpanded(false, for: intent.id)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if taskState.shouldPoll {
                ProgressView().controlSize(UITypography.controlSize(for: zoom, compact: true))
            }
            cloudPill
            Text("\(task.repo) · \(task.baseRef)")
                .uiFont(.caption2, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if taskState.shouldPoll {
                Text(intent.createdAt, style: .relative)
                    .uiFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var cloudPill: some View {
        let color = pillColor
        return HStack(spacing: 3) {
            Image(systemName: "cloud")
            Text(taskState.displayLabel)
        }
        .uiFont(.caption2, weight: .semibold)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }

    private var pillColor: Color {
        switch taskState {
        case .queued, .inProgress: return .accentColor
        case .waitingForUser, .idle: return .orange
        case .completed: return .green
        case .failed, .cancelled, .timedOut: return .red
        case .unknown: return .secondary
        }
    }

    private var attentionBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Copilot Cloud needs your input on GitHub.", systemImage: "hand.raised.fill")
                .uiFont(.caption, weight: .semibold)
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                if !task.htmlURL.isEmpty {
                    Button("Respond on GitHub") { state.openCloudURL(task.htmlURL) }
                }
                Button("Check now") { state.refreshCloudTask(intentID: intent.id) }
            }
            .uiFont(.caption)
            .controlSize(UITypography.controlSize(for: zoom))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
    }

    private var linksAndActionsRow: some View {
        HStack(spacing: 8) {
            if !task.htmlURL.isEmpty {
                Button {
                    state.openCloudURL(task.htmlURL)
                } label: {
                    Label("GitHub Task", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .uiFont(.caption)
            }
            if let prURL = task.pullRequestURL, !prURL.isEmpty {
                Button {
                    state.openCloudURL(prURL)
                } label: {
                    Label("Pull Request", systemImage: "arrow.triangle.pull")
                }
                .buttonStyle(.link)
                .uiFont(.caption)
            }
            Spacer()
            if taskState == .completed {
                Button("Insert into document") {
                    state.insertCloudResultIntoDocument(intentID: intent.id)
                }
                .uiFont(.caption)
                .controlSize(UITypography.controlSize(for: zoom))
            } else if taskState.shouldPoll {
                Button {
                    state.refreshCloudTask(intentID: intent.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check cloud task status now")
            }
        }
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                logExpanded.value.toggle()
                state.setCloudLogExpanded(logExpanded.value, for: intent.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: logExpanded.value ? "chevron.down" : "chevron.right")
                        .uiFont(size: 8, weight: .bold)
                    Text(logExpanded.value ? "Hide session log" : "Show session log")
                    if isStreaming {
                        Text("· live")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if logExpanded.value {
                ScrollView {
                    Text(logText.isEmpty ? (isStreaming ? "Waiting for log output…" : "No log output available yet.") : logText)
                        .uiFont(.caption, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140 * zoom)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
    }
}

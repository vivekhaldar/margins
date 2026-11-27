import MarginsCore
import SwiftUI

struct CloudComposerOptions: View {
    @EnvironmentObject var state: AppState
    @Environment(\.interfaceZoom) private var zoom
    @StateObject private var expanded = Local(false)
    let backend: CloudBackend

    private var isAmp: Bool { backend == .amp }
    private var needsInput: Bool {
        state.cloudRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!isAmp && state.cloudBaseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var authIssue: String? { state.cloudAuthIssue(for: backend) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded.value) {
            runOptions.padding(.top, 6)
        } label: {
            HStack(spacing: 4) {
                Text(summary).lineLimit(1).truncationMode(.middle)
                if authIssue != nil || state.cloudDirtyFilesCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(authIssue != nil ? Color.red : Color.orange)
                        .accessibilityLabel(authIssue != nil ? "Authentication needs attention" : "Uncommitted changes")
                }
            }
            .uiFont(.caption)
            .help(summary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        .onChange(of: needsInput, initial: true) { _, missing in
            if missing { expanded.value = true }
        }
        .onChange(of: authIssue, initial: true) { _, issue in
            if issue != nil { expanded.value = true }
        }
    }

    private var summary: String {
        let repo = state.cloudRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return "Set cloud repository" }
        if isAmp { return "\(repo) · \(state.ampDetached ? "Detached" : "Streaming")" }
        let branch = state.cloudBaseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(repo) · \(branch.isEmpty ? "Set base branch" : branch)"
    }

    private var runOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("owner/repo", text: $state.cloudRepo)
                    .textFieldStyle(.roundedBorder)
                    .uiFont(.caption, design: .monospaced)
                    .help(isAmp ? "Amp project: GitHub repository (owner/repo)" : "GitHub repository (owner/repo)")
                if !isAmp {
                    TextField("main", text: $state.cloudBaseRef)
                        .textFieldStyle(.roundedBorder)
                        .uiFont(.caption, design: .monospaced)
                        .frame(maxWidth: 110 * zoom)
                        .help("Base branch on GitHub")
                }
            }

            modeToggle

            if state.cloudDirtyFilesCount > 0 {
                let count = state.cloudDirtyFilesCount
                let base = isAmp ? "the pushed default branch" : (state.cloudBaseRef.isEmpty ? "base branch" : state.cloudBaseRef)
                Label(
                    "\(count) uncommitted local \(count == 1 ? "change" : "changes") — cloud runs against \(base) on GitHub.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .uiFont(.caption2)
                .foregroundStyle(.orange)
            }

            if let authIssue {
                CloudAuthCheck(backend: backend, issue: authIssue, authOnly: false)
            }
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 8) {
            Toggle(isAmp ? "Detached (fire & forget)" : "Open PR", isOn: isAmp ? $state.ampDetached : $state.cloudCreatePR)
                .toggleStyle(.switch)
                .controlSize(UITypography.controlSize(for: zoom, compact: true))
                .uiFont(.caption)
            Spacer()
            Text(modeCaption)
                .uiFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var modeCaption: String {
        if isAmp { return state.ampDetached ? "Submit only; follow on ampcode.com" : "Streams the answer back" }
        return state.cloudCreatePR ? "Creates a pull request" : "Read-only instructions"
    }
}

struct CloudAuthCheck: View {
    @EnvironmentObject var state: AppState
    let backend: CloudBackend
    let issue: String?
    let authOnly: Bool

    var body: some View {
        let checked = backend == .amp ? state.ampAuthStatus != nil : state.cloudAuthStatus != nil
        VStack(alignment: .leading, spacing: 4) {
            if let issue {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text(checked ? "Authenticated" : "Authentication not checked").foregroundStyle(.secondary)
            }
            Button(checked ? "Recheck" : "Check auth") {
                switch backend {
                case .copilot: state.refreshCopilotCloudContext(authOnly: authOnly)
                case .amp: state.refreshAmpCloudContext(recheck: true, authOnly: authOnly)
                }
            }
            .buttonStyle(.borderless)
        }
        .uiFont(.caption2)
    }
}

extension AppState {
    func cloudAuthIssue(for backend: CloudBackend) -> String? {
        switch backend {
        case .copilot:
            switch cloudAuthStatus {
            case .missingBinary: return "GitHub CLI (gh) not found. Run brew install gh, then gh auth login."
            case .notAuthenticated: return "Not logged in to GitHub CLI. Run gh auth login in Terminal."
            case .authenticated, .none: return nil
            }
        case .amp:
            switch ampAuthStatus {
            case .missingBinary: return "Amp CLI (amp) not found. Install it from ampcode.com."
            case .credentialUnavailable(let detail):
                return "Amp API key unavailable. \(detail)\nStore it with pass insert AMPCODE/API_KEY. If GPG is locked, Recheck opens pinentry-mac."
            case .ready, .none: return nil
            }
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
    private var isAmp: Bool { task.resolvedBackend == .amp }
    private var logText: String { state.cloudLogs[intent.id] ?? "" }
    private var isStreaming: Bool { state.cloudStreamingIntentIDs.contains(intent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if taskState.needsAttention && !isAmp {
                attentionBanner
            }
            linksAndActionsRow
            if task.sessionID != nil || !logText.isEmpty {
                logViewer
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if taskState.shouldPoll {
                ProgressView().controlSize(UITypography.controlSize(for: zoom, compact: true))
            }
            cloudPill
            Text(isAmp || task.baseRef.isEmpty ? task.repo : "\(task.repo) · \(task.baseRef)")
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
        case .completed, .submitted: return .green
        case .disconnected: return .orange
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
                    Label(isAmp ? "Amp Thread" : "GitHub Task", systemImage: "arrow.up.right.square")
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
            if taskState == .completed && intent.status != .pending && intent.status != .reviewed {
                Button("Insert into document") {
                    state.insertCloudResultIntoDocument(intentID: intent.id)
                }
                .uiFont(.caption)
                .controlSize(UITypography.controlSize(for: zoom))
            } else if taskState.shouldPoll && !isAmp {
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

import Foundation

/// Pure state transitions for Amp-backed intents (mirrors `CloudTaskLifecycle` for Copilot).
public enum AmpCloudLifecycle {
    public static let disconnectedMessage =
        "Outcome unknown: the stream closed before Amp reported a result. Open the Amp thread to check; Margins will not relaunch it."
    private static let maxLogLines = 400

    /// A new, not-yet-launched Amp reference.
    public static func newRef(project: String, paragraphBlockID: String? = nil) -> CloudTaskRef {
        CloudTaskRef(
            repo: project, baseRef: "", taskID: "", htmlURL: "",
            cloudState: CloudTaskState.queued.rawState, paragraphBlockID: paragraphBlockID, backend: .amp
        )
    }

    /// Records the remote thread as soon as `system/init` arrives (persisted before any result).
    /// Ignored once the turn has finished, so a late event never reopens it.
    public static func applyThread(_ threadID: String, to intent: inout Intent, at date: Date = Date()) {
        guard var ref = intent.cloudTask, AmpCloudClient.isValidThreadID(threadID),
              CloudTaskState(rawState: ref.cloudState).shouldPoll else { return }
        ref.taskID = threadID
        ref.sessionID = threadID
        ref.htmlURL = AmpCloudClient.threadURL(for: threadID) ?? ref.htmlURL
        ref.cloudState = CloudTaskState.inProgress.rawState
        ref.lastCheckedAt = date
        intent.cloudTask = ref
        if intent.status != .pending && intent.status != .reviewed { intent.status = .working }
    }

    /// Folds a finished turn into the intent; returns the new state.
    @discardableResult
    public static func apply(_ outcome: AmpTurnOutcome, to intent: inout Intent, at date: Date = Date()) -> CloudTaskState {
        if let id = outcome.threadID, AmpCloudClient.isValidThreadID(id) {
            intent.cloudTask?.taskID = id
            intent.cloudTask?.sessionID = id
            intent.cloudTask?.htmlURL = AmpCloudClient.threadURL(for: id) ?? ""
        }
        let state: CloudTaskState
        switch outcome {
        case .completed(_, let result):
            state = .completed
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { intent.reply = text }
            if intent.summary.isEmpty { intent.summary = "Amp thread completed." }
            intent.error = nil
        case .failed(_, let message):
            state = .failed
            intent.error = message.isEmpty ? "Amp run failed." : message
        case .disconnected(_, let detail):
            state = .disconnected
            intent.error = detail.isEmpty ? disconnectedMessage : "\(disconnectedMessage) (\(detail))"
        case .submitted:
            state = .submitted
            if intent.summary.isEmpty { intent.summary = "Submitted to Amp (detached)." }
        }
        setState(state, on: &intent, at: date)
        return state
    }

    /// When the app stops watching a run (cancel, close, quit): never-launched turns are cancelled;
    /// live ones become `disconnected` because the remote thread may still be running.
    @discardableResult
    public static func markStopped(_ intent: inout Intent, at date: Date = Date()) -> CloudTaskState? {
        guard let ref = intent.cloudTask, ref.resolvedBackend == .amp else { return nil }
        switch CloudTaskState(rawState: ref.cloudState) {
        case .queued where ref.taskID.isEmpty:
            intent.error = "Not launched: cancelled before Amp started."
            setState(.cancelled, on: &intent, at: date)
            return .cancelled
        case .queued, .inProgress:
            return apply(.disconnected(threadID: nil, detail: ""), to: &intent, at: date)
        default:
            return nil
        }
    }

    /// The Amp thread a new message in Margins thread `thread` continues: the latest saved T- ID there.
    public static func continuationThreadID(in intents: [Intent], thread: UUID?) -> String? {
        guard let thread else { return nil }
        return intents.last { intent in
            guard intent.thread == thread, let ref = intent.cloudTask, ref.resolvedBackend == .amp else { return false }
            return AmpCloudClient.isValidThreadID(ref.taskID)
        }?.cloudTask?.taskID
    }

    /// Appends streamed progress to the in-memory session log, keeping only the most recent lines.
    public static func appendingProgress(_ text: String, to log: String?) -> String {
        let lines = (log ?? "").split(separator: "\n", omittingEmptySubsequences: true)
            + text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(maxLogLines).joined(separator: "\n")
    }

    /// Notification for a state change. Disconnects caused by the user (cancel/quit) stay silent.
    public static func notificationOutcome(for intent: Intent, state: CloudTaskState) -> AgentNotificationOutcome? {
        switch state {
        case .completed:
            return .completed(hasEdits: false, summary: intent.summary, slug: "", reply: intent.reply ?? "")
        case .failed:
            return .failed(error: intent.error ?? "Amp run failed.")
        case .disconnected:
            return .permissionNeeded(title: "Amp Cloud outcome unknown", detail: "Open the Amp thread to check the result.")
        default:
            return nil
        }
    }

    private static func setState(_ state: CloudTaskState, on intent: inout Intent, at date: Date) {
        intent.cloudTask?.cloudState = state.rawState
        intent.cloudTask?.lastCheckedAt = date
        if intent.status != .pending && intent.status != .reviewed { intent.status = state.intentStatus }
    }
}

/// Runs Amp turns one at a time per key (a Margins thread), so follow-ups never race their predecessor.
public actor AmpTurnSerializer {
    private var tails: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    public init() {}

    public static func key(thread: UUID?, intentID: UUID) -> String {
        thread.map { "thread:\($0.uuidString)" } ?? "intent:\(intentID.uuidString)"
    }

    /// Waits for every earlier turn queued under `key`, then runs `operation`. Cancelling the caller
    /// cancels `operation` (earlier turns are unaffected).
    public func run(key: String, _ operation: @escaping @Sendable () async -> Void) async {
        let previous = tails[key]?.task
        let token = UUID()
        let task = Task {
            await previous?.value
            await operation()
        }
        tails[key] = (token, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if tails[key]?.token == token { tails[key] = nil }
    }
}

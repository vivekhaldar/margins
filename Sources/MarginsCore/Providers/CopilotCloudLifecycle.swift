import Foundation

/// The state change produced by folding one task snapshot into an intent.
public struct CloudSnapshotTransition: Equatable, Sendable {
    public var previousState: CloudTaskState
    public var newState: CloudTaskState

    public init(previousState: CloudTaskState, newState: CloudTaskState) {
        self.previousState = previousState
        self.newState = newState
    }

    /// Whether the watcher should keep polling / following the log.
    public var continuePolling: Bool { newState.shouldPoll }
}

/// Pure state transitions for cloud-backed intents, kept out of `AppState` so they can be self-tested.
public enum CloudTaskLifecycle {
    /// Folds a fresh snapshot into `intent.cloudTask` and the intent status. Review states (`pending`,
    /// `reviewed`) set by inserting the result are never overwritten. Returns nil for non-cloud intents.
    @discardableResult
    public static func apply(_ snapshot: CloudTaskSnapshot, to intent: inout Intent, at date: Date = Date()) -> CloudSnapshotTransition? {
        guard var ref = intent.cloudTask else { return nil }
        let previous = CloudTaskState(rawState: ref.cloudState)
        let next = CloudTaskState(rawState: snapshot.state)
        ref.cloudState = snapshot.state
        if !snapshot.htmlURL.isEmpty { ref.htmlURL = snapshot.htmlURL }
        if let sessionID = snapshot.sessionID { ref.sessionID = sessionID }
        ref.lastCheckedAt = date
        intent.cloudTask = ref
        if intent.status != .pending && intent.status != .reviewed {
            intent.status = next.intentStatus
        }
        return CloudSnapshotTransition(previousState: previous, newState: next)
    }

    /// Records what a finished (or attention-needing) task produced: PR link, the agent's answer, or the error.
    public static func applyOutputs(to intent: inout Intent, state: CloudTaskState, excerpt: String, pullRequestURL: String?) {
        intent.cloudTask?.pullRequestURL = pullRequestURL
        if state == .completed {
            if !excerpt.isEmpty { intent.reply = excerpt }
            if intent.summary.isEmpty {
                intent.summary = pullRequestURL != nil ? "Completed with pull request." : "Cloud task completed."
            }
        } else if state.needsAttention {
            if !excerpt.isEmpty { intent.reply = excerpt }
        } else if state.isTerminal, intent.error?.isEmpty ?? true {
            intent.error = excerpt.isEmpty ? "Cloud task \(state.displayLabel.lowercased())." : excerpt
        }
    }

    /// Attention states notify once per intent (they can repeat across polls); other states notify on change.
    public static func shouldNotify(state: CloudTaskState, previousState: CloudTaskState, alreadyNotifiedAttention: Bool) -> Bool {
        if state.needsAttention { return !alreadyNotifiedAttention }
        return previousState != state
    }
}

/// How a cloud result is inserted into the document as a tracked, reviewable edit.
public struct CloudInsertionPlan: Equatable, Sendable {
    public var edit: EditOp
    public var run: AnnotationRun

    public static let provider = CloudBackend.copilot.providerName

    /// - Parameters:
    ///   - focus: block ids currently selected in the editor.
    ///   - blockIDs: ids of all live blocks, in document order.
    public static func make(
        intent: Intent,
        log: String?,
        focus: [String],
        blockIDs: [String],
        runID: UUID = UUID(),
        createdAt: Date = Date()
    ) -> CloudInsertionPlan? {
        guard let task = intent.cloudTask else { return nil }
        let html = CloudTaskFormatter.insertionHTML(
            intentText: intent.text,
            reply: intent.reply,
            log: log,
            summary: intent.summary,
            pullRequestURL: task.pullRequestURL,
            htmlURL: task.htmlURL,
            backend: task.resolvedBackend
        )
        let run = AnnotationRun(
            id: runID,
            intentId: intent.id,
            step: intent.step,
            provider: task.resolvedBackend.providerName,
            model: task.repo,
            createdAt: createdAt,
            instruction: intent.text,
            summary: intent.summary,
            status: "pending"
        )
        let edit = targetEdit(intent: intent, html: html, focus: focus, blockIDs: blockIDs)
        return CloudInsertionPlan(edit: edit, run: run)
    }

    /// Direct paragraph prompts replace their rough prompt block when still present; otherwise insert
    /// after the thread passage, current selection, or end of the document.
    public static func targetEdit(intent: Intent, html: String, focus: [String], blockIDs: [String]) -> EditOp {
        if let blockID = intent.cloudTask?.paragraphBlockID, blockIDs.contains(blockID) {
            return EditOp(op: .replace, blockId: blockID, html: html)
        }
        let target = targetBlockID(intent: intent, focus: focus, blockIDs: blockIDs)
        return EditOp(op: .insertAfter, blockId: target, html: html)
    }

    /// Selection threads and direct paragraph prompts auto-apply their tracked edit on completion
    /// unless already inserted into the document.
    public static func shouldAutoInsert(intent: Intent) -> Bool {
        guard let task = intent.cloudTask else { return false }
        guard intent.status != .pending && intent.status != .reviewed else { return false }
        return intent.thread != nil || task.paragraphBlockID != nil
    }

    /// Thread results go right after the discussed passage; otherwise after the current selection, else at
    /// the end of the document ("^" = start of an empty document).
    public static func targetBlockID(intent: Intent, focus: [String], blockIDs: [String]) -> String {
        let live = Set(blockIDs)
        if intent.thread != nil {
            let threadBlocks = (intent.focus ?? []) + [intent.anchor].compactMap { $0 }
            if let last = blockIDs.last(where: { threadBlocks.contains($0) }) { return last }
        }
        if let selected = focus.last(where: live.contains) { return selected }
        return blockIDs.last ?? "^"
    }

    /// Intent status after the tracked edit lands: pending review if anything changed.
    public static func status(afterChanges changes: Int) -> Intent.Status {
        changes == 0 ? .done : .pending
    }
}

extension Intent {
    /// One-line status for a cloud-backed intent (nil for local agents), e.g. "Copilot Cloud · In progress".
    public var cloudActivity: String? {
        cloudTask.map { "\($0.resolvedBackend.providerName) · \(CloudTaskState(rawState: $0.cloudState).displayLabel)" }
    }
}

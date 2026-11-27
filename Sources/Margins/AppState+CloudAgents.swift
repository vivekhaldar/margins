import AppKit
import Foundation
import MarginsCore

/// The selected passage an inline thread is anchored to; cloud tasks launched from a thread carry it.
struct CloudThreadAnchor {
    var id: UUID
    var quote: String
    var focus: [String]
    var anchor: String
}

extension AppState {
    private static let cloudQueuedPollIntervalNanoseconds: UInt64 = 10_000_000_000
    private static let cloudReconnectDelayNanoseconds: UInt64 = 5_000_000_000

    // MARK: - Context & Preflight

    func refreshCopilotCloudContext(authOnly: Bool = false) {
        let project = projectURL
        let repo = cloudRepo
        let baseRef = cloudBaseRef
        let repoMissing = repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let refMissing = baseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let session = documentSessionID
        let client = cloudClient

        Task {
            let auth = await client.checkAuth()
            guard documentSessionID == session else { return }
            cloudAuthStatus = auth
            guard !authOnly, activeCloudBackend != .amp, projectURL == project else { return }

            if let project {
                let dirtyCount = await Task.detached { ProjectChanges.snapshot(project)?.count ?? 0 }.value
                guard documentSessionID == session, activeCloudBackend != .amp, projectURL == project else { return }
                cloudDirtyFilesCount = dirtyCount

                if repoMissing || refMissing, let info = try? await client.resolveRepo(in: project) {
                    guard documentSessionID == session, activeCloudBackend != .amp, projectURL == project else { return }
                    if repoMissing && cloudRepo == repo { cloudRepo = info.repo }
                    if cloudRepo == info.repo && cloudBaseRef == baseRef { cloudBaseRef = info.defaultBranch }
                }
            } else {
                cloudDirtyFilesCount = 0
            }
        }
    }

    // MARK: - Launch

    /// Editor "ask" message from an inline thread: follows the main composer's Local/Cloud setting.
    func routeThreadMessage(_ body: [String: Any]) {
        guard let thread = (body["thread"] as? String).flatMap(UUID.init(uuidString:)),
              let message = body["message"] as? String else { return }
        let quote = body["quote"] as? String ?? ""
        let focus = body["focus"] as? [String] ?? []
        let anchor = body["anchor"] as? String ?? ""
        guard isCloudTarget else {
            discuss(thread: thread, quote: quote, focus: focus, anchor: anchor, message: message)
            return
        }
        // Later messages stay anchored where the thread started, like local discussions.
        let first = doc.intents.first { $0.kind == .instruction && $0.thread == thread }
        let step = doc.nextStep
        submitCloud(message, thread: CloudThreadAnchor(
            id: thread,
            quote: first?.quote ?? quote,
            focus: first?.focus ?? focus,
            anchor: first?.anchor ?? anchor
        ))
        if doc.nextStep == step {
            // Launch was refused (e.g. no repo): drop the editor's optimistic "working" bubble.
            lastThreadsJSON = ""
            scheduleThreads()
        }
    }

    /// Direct `⌘↩` prompt on a document paragraph: follows the main composer's Local/Cloud setting.
    func routeParagraphPrompt(_ raw: String, blockID: String) {
        if isCloudTarget {
            submitCloud(raw, paragraphBlockID: blockID)
        } else {
            submit(raw, paragraphBlockID: blockID)
        }
    }

    func submitCopilotCloud(_ raw: String, thread: CloudThreadAnchor?, paragraphBlockID: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let repo = cloudRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseRef = cloudBaseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            lastError = "Enter a GitHub repository (`owner/repo`) before launching a cloud task."
            return
        }
        guard !baseRef.isEmpty else {
            lastError = "Enter a base branch before launching a cloud task."
            return
        }

        previewing = nil
        prepareAgentNotifications()
        let step = doc.nextStep
        doc.nextStep += 1
        var intent = Intent(step: step, text: text, status: .working, provider: CloudInsertionPlan.provider)
        if let thread {
            intent.thread = thread.id
            intent.quote = thread.quote
            intent.focus = thread.focus
            intent.anchor = thread.anchor
        }
        doc.intents.append(intent)
        let intentID = intent.id
        let session = documentSessionID
        let createPR = cloudCreatePR
        let client = cloudClient

        Task {
            if let paragraphBlockID { await editor.setParagraphWorking(step: step, blockID: paragraphBlockID) }
            do {
                let excerpt = await cloudExcerpt(thread: thread)
                guard documentSessionID == session else { return }
                let request = CloudTaskRequest(
                    repo: repo,
                    baseRef: baseRef,
                    instruction: text,
                    excerpt: excerpt,
                    createPullRequest: createPR
                )
                let snapshot = try await client.startTask(request)
                guard documentSessionID == session else { return }
                let ref = CloudTaskRef(
                    repo: repo,
                    baseRef: baseRef,
                    taskID: snapshot.taskID,
                    htmlURL: snapshot.htmlURL,
                    sessionID: snapshot.sessionID,
                    cloudState: snapshot.state,
                    lastCheckedAt: Date(),
                    createPullRequest: createPR,
                    paragraphBlockID: paragraphBlockID
                )
                updateCloudIntent(intentID) { $0.cloudTask = ref }
                saveNow()
                if CloudTaskState(rawState: snapshot.state).shouldPoll {
                    startCloudPolling(for: intentID)
                } else {
                    await applyCloudSnapshot(snapshot, to: intentID, session: session)
                }
            } catch {
                guard documentSessionID == session else { return }
                if paragraphBlockID != nil { await editor.setParagraphWorking(step: step, blockID: nil) }
                updateCloudIntent(intentID) {
                    $0.status = .failed
                    $0.error = error.localizedDescription
                }
                saveNow()
            }
        }
    }

    // MARK: - Polling Lifecycle

    /// Focus only fills gaps (a live `--log --follow` stream is left alone); wake restarts every watcher
    /// because `gh` children may be stuck on sockets that died while the machine slept.
    func pollActiveCloudTasksImmediately(trigger: CloudReconcileTrigger) {
        refreshCloudContext(forceRepoResolve: false)
        startCloudWatchers(trigger: trigger)
    }

    func startCloudWatchers(trigger: CloudReconcileTrigger) {
        for intent in doc.intents {
            guard let task = intent.cloudTask,
                  CloudWatcherPolicy.shouldWatch(task),
                  CloudWatcherPolicy.shouldStartWatcher(trigger: trigger, watcherRunning: cloudPollTasks[intent.id] != nil)
            else { continue }
            if let blockID = task.paragraphBlockID {
                Task { await editor.setParagraphWorking(step: intent.step, blockID: blockID) }
            }
            startCloudPolling(for: intent.id)
        }
    }

    func refreshCloudTask(intentID: UUID) {
        let session = documentSessionID
        Task {
            let shouldContinue = await pollCloudOnce(intentID: intentID, session: session)
            if shouldContinue, documentSessionID == session {
                startCloudPolling(for: intentID)
            }
        }
    }

    func cancelCopilotCloudWatchers() {
        for task in cloudPollTasks.values { task.cancel() }
        cloudPollTasks.removeAll()
        for task in cloudLogTasks.values { task.cancel() }
        cloudLogTasks.removeAll()
        cloudStreamingIntentIDs.removeAll()
        cloudNotifiedAttention.removeAll()
    }

    func startCloudPolling(for intentID: UUID) {
        cloudPollTasks[intentID]?.cancel()
        stopCloudLogStream(for: intentID)
        let session = documentSessionID
        cloudPollTasks[intentID] = Task { [weak self] in
            defer {
                if let self, self.documentSessionID == session {
                    self.cloudPollTasks[intentID] = nil
                    self.cloudStreamingIntentIDs.remove(intentID)
                }
            }
            while !Task.isCancelled {
                guard let self, self.documentSessionID == session else { return }
                let shouldContinue = await self.pollCloudOnce(intentID: intentID, session: session)
                guard shouldContinue, !Task.isCancelled else { return }
                if let ref = self.cloudTaskRef(for: intentID), let sessionID = ref.sessionID {
                    await self.followCloudSessionLog(intentID: intentID, repo: ref.repo, sessionID: sessionID, session: session)
                    guard !Task.isCancelled else { return }
                    let stillActive = await self.pollCloudOnce(intentID: intentID, session: session)
                    guard stillActive, !Task.isCancelled else { return }
                    try? await Task.sleep(nanoseconds: Self.cloudReconnectDelayNanoseconds)
                } else {
                    try? await Task.sleep(nanoseconds: Self.cloudQueuedPollIntervalNanoseconds)
                }
            }
        }
    }

    private func followCloudSessionLog(intentID: UUID, repo: String, sessionID: String, session: UUID) async {
        guard documentSessionID == session else { return }
        cloudStreamingIntentIDs.insert(intentID)
        defer {
            if documentSessionID == session {
                cloudStreamingIntentIDs.remove(intentID)
            }
        }
        let stream = CloudLogStreamBox(existing: cloudLogs[intentID])
        let client = cloudClient
        _ = try? await client.streamSessionLog(repo: repo, sessionID: sessionID) { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard stream.isActive, let self, self.documentSessionID == session,
                          let text = stream.accumulator.append(line) else { return }
                    self.cloudLogs[intentID] = text
                }
            }
        }
        stream.isActive = false
        // A replay shorter than what was shown (e.g. GitHub trimmed the log) still wins once it ends cleanly.
        if !Task.isCancelled, documentSessionID == session, !stream.accumulator.text.isEmpty {
            cloudLogs[intentID] = stream.accumulator.text
        }
    }

    private func cloudTaskRef(for intentID: UUID) -> CloudTaskRef? {
        doc.intents.first(where: { $0.id == intentID })?.cloudTask
    }

    private func pollCloudOnce(intentID: UUID, session: UUID) async -> Bool {
        guard documentSessionID == session,
              let intent = doc.intents.first(where: { $0.id == intentID }),
              let task = intent.cloudTask, task.resolvedBackend == .copilot else { return false }
        do {
            let snapshot = try await cloudClient.fetchTask(repo: task.repo, id: task.taskID)
            guard documentSessionID == session else { return false }
            return await applyCloudSnapshot(snapshot, to: intentID, session: session)
        } catch {
            guard documentSessionID == session else { return false }
            updateCloudIntent(intentID) { $0.cloudTask?.lastCheckedAt = Date() }
            return CloudTaskState(rawState: task.cloudState).shouldPoll
        }
    }

    @discardableResult
    private func applyCloudSnapshot(_ snapshot: CloudTaskSnapshot, to intentID: UUID, session: UUID) async -> Bool {
        guard documentSessionID == session,
              let index = doc.intents.lastIndex(where: { $0.id == intentID }),
              let transition = CloudTaskLifecycle.apply(snapshot, to: &doc.intents[index]),
              let ref = doc.intents[index].cloudTask else { return false }

        if transition.continuePolling {
            scheduleSave()
            return true
        }

        stopCloudLogStream(for: intentID)
        if ref.paragraphBlockID != nil {
            await editor.setParagraphWorking(step: doc.intents[index].step, blockID: nil)
        }
        await collectCloudOutputs(
            for: intentID, ref: ref, state: transition.newState, previousState: transition.previousState, session: session
        )
        return false
    }

    private func collectCloudOutputs(
        for intentID: UUID,
        ref: CloudTaskRef,
        state: CloudTaskState,
        previousState: CloudTaskState,
        session: UUID
    ) async {
        var logText = cloudLogs[intentID] ?? ""
        var prURL = ref.pullRequestURL

        if let sessionID = ref.sessionID {
            if state == .completed,
               let meta = try? await cloudClient.fetchSessionMetadata(repo: ref.repo, sessionID: sessionID),
               let fetchedPR = meta.pullRequestURL, !fetchedPR.isEmpty {
                prURL = fetchedPR
            }
            if let fetchedLog = try? await cloudClient.fetchSessionLog(repo: ref.repo, sessionID: sessionID),
               !fetchedLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logText = fetchedLog
            }
        }
        guard documentSessionID == session else { return }

        if !logText.isEmpty { cloudLogs[intentID] = logText }
        let excerpt = CloudTaskFormatter.extractSummary(fromLog: logText)

        updateCloudIntent(intentID) {
            CloudTaskLifecycle.applyOutputs(to: &$0, state: state, excerpt: excerpt, pullRequestURL: prURL)
        }
        saveNow()
        if state == .completed,
           let updated = doc.intents.first(where: { $0.id == intentID }),
           CloudInsertionPlan.shouldAutoInsert(intent: updated) {
            await applyCloudResultToDocument(intentID: intentID, allowEndPreview: false)
            guard documentSessionID == session else { return }
        }
        notifyCloudTransition(intentID: intentID, state: state, previousState: previousState, excerpt: excerpt)
    }

    private func notifyCloudTransition(intentID: UUID, state: CloudTaskState, previousState: CloudTaskState, excerpt: String) {
        guard let intent = doc.intents.first(where: { $0.id == intentID }),
              CloudTaskLifecycle.shouldNotify(
                  state: state, previousState: previousState, alreadyNotifiedAttention: cloudNotifiedAttention.contains(intentID)
              ) else { return }
        if state.needsAttention { cloudNotifiedAttention.insert(intentID) }
        guard let outcome = state.notificationOutcome(
            summary: intent.summary, detail: excerpt, error: intent.error, hasEdits: intent.status == .pending
        ) else { return }
        AgentNotifications.shared.coordinator.notify(
            documentURL: fileURL,
            step: intent.step,
            intentID: intent.id,
            threadID: intent.thread,
            outcome: outcome,
            wasCancelled: false,
            isDocumentFocused: isDocumentWindowFocused
        )
    }

    // MARK: - Live Log Viewer

    func setCloudLogExpanded(_ expanded: Bool, for intentID: UUID) {
        guard expanded else { return }
        guard let intent = doc.intents.first(where: { $0.id == intentID }),
              let task = intent.cloudTask, task.resolvedBackend == .copilot,
              let sessionID = task.sessionID else { return }

        let state = CloudTaskState(rawState: task.cloudState)
        if state.shouldPoll {
            if cloudPollTasks[intentID] == nil {
                startCloudPolling(for: intentID)
            }
            return
        }

        guard (cloudLogs[intentID] ?? "").isEmpty else { return }
        let session = documentSessionID
        let client = cloudClient
        cloudLogTasks[intentID]?.cancel()
        cloudLogTasks[intentID] = Task { [weak self] in
            defer {
                if let self, self.documentSessionID == session {
                    self.cloudLogTasks[intentID] = nil
                }
            }
            if let log = try? await client.fetchSessionLog(repo: task.repo, sessionID: sessionID),
               let self, self.documentSessionID == session {
                self.cloudLogs[intentID] = log
            }
        }
    }

    private func stopCloudLogStream(for intentID: UUID) {
        cloudLogTasks.removeValue(forKey: intentID)?.cancel()
        cloudStreamingIntentIDs.remove(intentID)
    }

    // MARK: - Insert into Document (Tracked Edit)

    func insertCloudResultIntoDocument(intentID: UUID) {
        Task { await applyCloudResultToDocument(intentID: intentID, allowEndPreview: true) }
    }

    func applyCloudResultToDocument(intentID: UUID, allowEndPreview: Bool) async {
        if !allowEndPreview && previewing != nil { return }
        guard let intent = doc.intents.first(where: { $0.id == intentID }), intent.cloudTask != nil else { return }
        let log = cloudLogs[intentID]
        let session = documentSessionID
        if allowEndPreview { previewing = nil }

        do {
            let snapshot = try await editor.blocks()
            guard documentSessionID == session,
                  let plan = CloudInsertionPlan.make(
                      intent: intent, log: log, focus: snapshot.focus, blockIDs: snapshot.blocks.map(\.id)
                  ) else { return }
            doc.annotationRuns.append(plan.run)
            let result = try await editor.apply(
                step: intent.step,
                edits: [plan.edit],
                direct: false,
                runID: plan.run.id,
                expectedRevision: snapshot.revision,
                blockStates: snapshot.blockStates
            )
            guard documentSessionID == session else { return }
            updateCloudIntent(intentID) {
                $0.status = CloudInsertionPlan.status(afterChanges: result.changes)
            }
            doc.snapshot(
                html: result.html,
                slug: "inserted cloud result",
                author: .agent,
                detail: intent.text,
                annotations: result.annotations
            )
            saveNow()
        } catch {
            guard documentSessionID == session else { return }
            lastError = "Couldn't insert cloud result: \(error.localizedDescription)"
        }
    }

    func openCloudURL(_ raw: String) {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    func updateCloudIntent(_ id: UUID, _ body: (inout Intent) -> Void) {
        guard let index = doc.intents.lastIndex(where: { $0.id == id }) else { return }
        body(&doc.intents[index])
    }

    func cloudExcerpt(thread: CloudThreadAnchor?) async -> String? {
        if let quote = thread?.quote.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            return String(quote.prefix(3000))
        }
        return await cloudDocumentExcerpt()
    }

    private func cloudDocumentExcerpt() async -> String? {
        guard let snapshot = try? await editor.blocks(), !snapshot.blocks.isEmpty else { return nil }
        let selected: [Block]
        if !snapshot.focus.isEmpty {
            let focusSet = Set(snapshot.focus)
            selected = snapshot.blocks.filter { focusSet.contains($0.id) }
        } else {
            selected = Array(snapshot.blocks.prefix(12))
        }
        let plain = selected
            .map { $0.html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
            .map { $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !plain.isEmpty else { return nil }
        return String(plain.prefix(3000))
    }
}

/// Main-actor state for one live log stream; main-actor isolation makes it safe to capture in the
/// `@Sendable` line callback without a lock or a captured `var`.
@MainActor
private final class CloudLogStreamBox {
    var accumulator: CloudLogStreamAccumulator
    var isActive = true

    init(existing: String?) {
        accumulator = CloudLogStreamAccumulator(existing: existing)
    }
}

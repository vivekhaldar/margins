import AppKit
import Foundation
import MarginsCore

enum ComposerTarget: String, CaseIterable {
    case local
    case cloud
}

extension AppState {
    private static let cloudQueuedPollIntervalNanoseconds: UInt64 = 10_000_000_000
    private static let cloudReconnectDelayNanoseconds: UInt64 = 5_000_000_000

    // MARK: - Context & Preflight

    func refreshCloudContext(forceRepoResolve: Bool = false) {
        let project = projectURL
        let shouldResolve = forceRepoResolve || cloudRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let session = documentSessionID
        let client = cloudClient

        Task {
            let auth = await client.checkAuth()
            guard documentSessionID == session else { return }
            cloudAuthStatus = auth

            if let project {
                let dirtyCount = await Task.detached { ProjectChanges.snapshot(project)?.count ?? 0 }.value
                guard documentSessionID == session else { return }
                cloudDirtyFilesCount = dirtyCount

                if shouldResolve, let info = try? await client.resolveRepo(in: project) {
                    guard documentSessionID == session else { return }
                    cloudRepo = info.repo
                    cloudBaseRef = info.defaultBranch
                }
            } else {
                cloudDirtyFilesCount = 0
                if forceRepoResolve {
                    cloudRepo = ""
                    cloudBaseRef = "main"
                }
            }
        }
    }

    // MARK: - Launch

    func submitCloud(_ raw: String) {
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
        let intent = Intent(step: step, text: text, status: .working, provider: "Copilot Cloud")
        doc.intents.append(intent)
        let intentID = intent.id
        let session = documentSessionID
        let createPR = cloudCreatePR
        let client = cloudClient

        Task {
            do {
                let excerpt = await cloudDocumentExcerpt()
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
                    createPullRequest: createPR
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
                updateCloudIntent(intentID) {
                    $0.status = .failed
                    $0.error = error.localizedDescription
                }
                saveNow()
            }
        }
    }

    // MARK: - Polling Lifecycle

    func resumeCloudPolling() {
        for intent in doc.intents {
            guard let task = intent.cloudTask,
                  CloudTaskState(rawState: task.cloudState).shouldPoll,
                  cloudPollTasks[intent.id] == nil else { continue }
            startCloudPolling(for: intent.id)
        }
    }

    func pollActiveCloudTasksImmediately() {
        refreshCloudContext(forceRepoResolve: false)
        for intent in doc.intents {
            guard let task = intent.cloudTask,
                  CloudTaskState(rawState: task.cloudState).shouldPoll else { continue }
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

    func cancelCloudPolling() {
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
        var receivedFirstLine = false
        let lineLock = NSLock()
        let client = cloudClient
        _ = try? await client.streamSessionLog(repo: repo, sessionID: sessionID) { [weak self] line in
            lineLock.lock()
            let isFirstLine = !receivedFirstLine
            receivedFirstLine = true
            lineLock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.documentSessionID == session else { return }
                    if isFirstLine {
                        self.cloudLogs[intentID] = line
                    } else {
                        let current = self.cloudLogs[intentID] ?? ""
                        self.cloudLogs[intentID] = current.isEmpty ? line : current + "\n" + line
                    }
                }
            }
        }
    }

    private func cloudTaskRef(for intentID: UUID) -> CloudTaskRef? {
        doc.intents.first(where: { $0.id == intentID })?.cloudTask
    }

    private func pollCloudOnce(intentID: UUID, session: UUID) async -> Bool {
        guard documentSessionID == session,
              let intent = doc.intents.first(where: { $0.id == intentID }),
              let task = intent.cloudTask else { return false }
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
              let existing = doc.intents.first(where: { $0.id == intentID }),
              var ref = existing.cloudTask else { return false }

        let previousState = CloudTaskState(rawState: ref.cloudState)
        let newState = CloudTaskState(rawState: snapshot.state)
        ref.cloudState = snapshot.state
        if !snapshot.htmlURL.isEmpty { ref.htmlURL = snapshot.htmlURL }
        if let sessionID = snapshot.sessionID { ref.sessionID = sessionID }
        ref.lastCheckedAt = Date()

        updateCloudIntent(intentID) {
            $0.cloudTask = ref
            if $0.status != .pending && $0.status != .reviewed {
                $0.status = newState.intentStatus
            }
        }

        if newState.shouldPoll {
            scheduleSave()
            return true
        }

        stopCloudLogStream(for: intentID)
        await collectCloudOutputs(for: intentID, ref: ref, state: newState, previousState: previousState, session: session)
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

        updateCloudIntent(intentID) { intent in
            intent.cloudTask?.pullRequestURL = prURL
            if state == .completed {
                if !excerpt.isEmpty { intent.reply = excerpt }
                if intent.summary.isEmpty {
                    intent.summary = prURL != nil ? "Completed with pull request." : "Cloud task completed."
                }
            } else if state.needsAttention {
                if !excerpt.isEmpty { intent.reply = excerpt }
            } else if state.isTerminal {
                if intent.error == nil || intent.error?.isEmpty == true {
                    intent.error = excerpt.isEmpty ? "Cloud task \(state.displayLabel.lowercased())." : excerpt
                }
            }
        }
        saveNow()
        notifyCloudTransition(intentID: intentID, state: state, previousState: previousState, excerpt: excerpt)
    }

    private func notifyCloudTransition(intentID: UUID, state: CloudTaskState, previousState: CloudTaskState, excerpt: String) {
        guard let intent = doc.intents.first(where: { $0.id == intentID }) else { return }
        if state.needsAttention {
            guard cloudNotifiedAttention.insert(intentID).inserted else { return }
        } else if previousState == state {
            return
        }
        guard let outcome = state.notificationOutcome(summary: intent.summary, detail: excerpt, error: intent.error) else { return }
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
              let task = intent.cloudTask,
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
        guard let intent = doc.intents.first(where: { $0.id == intentID }),
              let task = intent.cloudTask else { return }
        let html = CloudTaskFormatter.insertionHTML(
            intentText: intent.text,
            reply: intent.reply,
            log: cloudLogs[intentID],
            summary: intent.summary,
            pullRequestURL: task.pullRequestURL,
            htmlURL: task.htmlURL
        )
        let session = documentSessionID
        let step = intent.step
        previewing = nil

        Task {
            do {
                let snapshot = try await editor.blocks()
                guard documentSessionID == session else { return }
                let targetBlockID = snapshot.focus.last ?? snapshot.blocks.last?.id ?? "^"
                let run = AnnotationRun(
                    intentId: intent.id,
                    step: step,
                    provider: "Copilot Cloud",
                    model: task.repo,
                    instruction: intent.text,
                    summary: intent.summary,
                    status: "pending"
                )
                doc.annotationRuns.append(run)
                let edit = EditOp(op: .insertAfter, blockId: targetBlockID, html: html)
                let result = try await editor.apply(
                    step: step,
                    edits: [edit],
                    direct: false,
                    runID: run.id,
                    expectedRevision: snapshot.revision,
                    blockStates: snapshot.blockStates
                )
                guard documentSessionID == session else { return }
                updateCloudIntent(intentID) {
                    $0.status = result.changes == 0 ? .done : .pending
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
    }

    func openCloudURL(_ raw: String) {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func updateCloudIntent(_ id: UUID, _ body: (inout Intent) -> Void) {
        guard let index = doc.intents.lastIndex(where: { $0.id == id }) else { return }
        body(&doc.intents[index])
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

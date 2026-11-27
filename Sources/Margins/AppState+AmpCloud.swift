import Foundation
import MarginsCore

/// Amp Cloud Agents (`amp -ox`): a cloud-only backend next to Copilot Cloud. Amp runs are watched only
/// through their own launch stream — focus, wake and reopen never invoke `amp` (a `threads continue`
/// would send a new prompt), so an interrupted stream is reported as "Outcome unknown" instead.
extension AppState {
    var ampClient: AmpCloudClient { Self.sharedAmpClient }

    // MARK: - Routing

    /// Launches a cloud run. Follow-ups in a thread that already talks to Amp stay on Amp; everything
    /// else follows the selected cloud agent.
    func submitCloud(_ raw: String, thread: CloudThreadAnchor? = nil, paragraphBlockID: String? = nil) {
        let ampThread = thread.map { anchor in
            doc.intents.contains { $0.thread == anchor.id && $0.cloudTask?.resolvedBackend == .amp }
        } ?? false
        guard let backend = agentTarget.cloudBackendForSubmission(
            continuingAmpThread: ampThread, enabledCloud: enabledCloudBackends
        ) else {
            lastError = ampThread ? "Enable Amp Cloud in Providers to continue this thread." : "Choose an enabled cloud agent."
            return
        }
        if backend == .amp {
            submitAmpCloud(raw, thread: thread, paragraphBlockID: paragraphBlockID)
        } else {
            submitCopilotCloud(raw, thread: thread, paragraphBlockID: paragraphBlockID)
        }
    }

    func refreshCloudContext(forceRepoResolve: Bool = false) {
        if forceRepoResolve {
            // Never leave the previous project's destination launchable while resolution is in flight.
            cloudRepo = ""
            cloudBaseRef = projectURL == nil ? "main" : ""
            cloudDirtyFilesCount = 0
        }
        switch activeCloudBackend ?? .copilot {
        case .copilot: refreshCopilotCloudContext()
        case .amp: refreshAmpCloudContext(recheck: false)
        }
    }

    /// Document opened or reloaded: restart Copilot watchers; Amp runs without a live stream in this
    /// window can't be reattached, so they become "Outcome unknown" (never relaunched).
    func resumeCloudPolling() {
        var changed = false
        for index in doc.intents.indices where ampStreamTasks[doc.intents[index].id] == nil {
            if AmpCloudLifecycle.markStopped(&doc.intents[index]) != nil { changed = true }
        }
        if changed { scheduleSave() }
        startCloudWatchers(trigger: .open)
    }

    /// Stop / close / quit / document switch: stop watching. Live Amp turns are marked silently.
    func cancelCloudPolling() {
        cancelCopilotCloudWatchers()
        let live = Array(ampStreamTasks.keys)
        ampStreamTasks.values.forEach { $0.cancel() }
        ampStreamTasks.removeAll()
        var changed = false
        for id in live {
            updateCloudIntent(id) {
                if AmpCloudLifecycle.markStopped(&$0) != nil { changed = true }
            }
            cloudStreamingIntentIDs.remove(id)
        }
        if changed { saveNow() }
    }

    /// Cancels a single running Amp turn (e.g. from the Stop button on a card, thread, or paragraph).
    func stopAmpTurn(step: Int) {
        guard let intent = doc.intents.last(where: {
            $0.step == step && $0.cloudTask?.resolvedBackend == .amp && ampStreamTasks[$0.id] != nil
        }) else { return }
        let id = intent.id
        ampStreamTasks.removeValue(forKey: id)?.cancel()
        cloudStreamingIntentIDs.remove(id)
        var changed = false
        updateCloudIntent(id) {
            if AmpCloudLifecycle.markStopped(&$0) != nil { changed = true }
        }
        if intent.cloudTask?.paragraphBlockID != nil {
            Task { await editor.setParagraphWorking(step: step, blockID: nil) }
        }
        if changed { saveNow() }
    }

    // MARK: - Context & Preflight

    /// Resolves the project from `git remote get-url origin` and counts dirty files. The CLI / key
    /// preflight (which may run `pass`) happens once per window, or when the user presses Recheck.
    func refreshAmpCloudContext(recheck: Bool, authOnly: Bool = false) {
        let project = projectURL
        let needsPreflight = recheck || ampAuthStatus == nil
        let session = documentSessionID
        let client = ampClient
        Task {
            if !authOnly {
                await resolveAmpContext(project: project, session: session)
            }
            guard needsPreflight else { return }
            if recheck { await client.credentials.invalidate() }
            let status = await client.preflight()
            guard documentSessionID == session else { return }
            ampAuthStatus = status
        }
    }

    private func resolveAmpContext(project: URL?, session: UUID) async {
        guard documentSessionID == session, activeCloudBackend == .amp, projectURL == project else { return }
        guard let project else {
            cloudDirtyFilesCount = 0
            return
        }
        let repo = cloudRepo
        if repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let resolved = try? await ampClient.resolveProject(in: project),
           documentSessionID == session, activeCloudBackend == .amp, projectURL == project, cloudRepo == repo {
            cloudRepo = resolved
        }
        let dirtyCount = await Task.detached { ProjectChanges.snapshot(project)?.count ?? 0 }.value
        guard documentSessionID == session, activeCloudBackend == .amp, projectURL == project else { return }
        cloudDirtyFilesCount = dirtyCount
    }

    // MARK: - Launch

    func submitAmpCloud(_ raw: String, thread: CloudThreadAnchor?, paragraphBlockID: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let earlier = thread.flatMap { anchor in
            doc.intents.last { $0.thread == anchor.id && $0.cloudTask?.resolvedBackend == .amp }
        }
        let project = earlier?.cloudTask?.repo ?? cloudRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? AmpCloudClient.validateProject(project)) != nil else {
            lastError = "Enter a GitHub project (`owner/repo`) before launching an Amp cloud run."
            return
        }

        previewing = nil
        prepareAgentNotifications()
        let step = doc.nextStep
        doc.nextStep += 1
        var intent = Intent(
            step: step, text: text, status: .working, provider: CloudBackend.amp.providerName,
            cloudTask: AmpCloudLifecycle.newRef(project: project, paragraphBlockID: paragraphBlockID)
        )
        if let thread {
            intent.thread = thread.id
            intent.quote = thread.quote
            intent.focus = thread.focus
            intent.anchor = thread.anchor
        }
        doc.intents.append(intent)
        saveNow()

        let intentID = intent.id
        // Detached runs return no answer, so thread follow-ups always stream.
        let detached = ampDetached && earlier == nil
        let key = AmpTurnSerializer.key(thread: thread?.id, intentID: intentID)
        let session = documentSessionID
        let serializer = ampSerializer
        let turn: @Sendable () async -> Void = { [weak self] in
            await self?.runAmpTurn(intentID: intentID, thread: thread, detached: detached, session: session)
        }
        ampStreamTasks[intentID] = Task { [weak self] in
            await serializer.run(key: key, turn)
            guard let self, self.documentSessionID == session else { return }
            self.ampStreamTasks[intentID] = nil
        }
    }

    /// One turn, started only after earlier turns in the same Margins thread finished, so a follow-up
    /// continues the Amp thread its predecessor created.
    private func runAmpTurn(intentID: UUID, thread: CloudThreadAnchor?, detached: Bool, session: UUID) async {
        guard !Task.isCancelled, documentSessionID == session,
              let intent = doc.intents.first(where: { $0.id == intentID }),
              let ref = intent.cloudTask else { return }
        let continuation = AmpCloudLifecycle.continuationThreadID(in: doc.intents, thread: thread?.id)
        if let blockID = ref.paragraphBlockID { await editor.setParagraphWorking(step: intent.step, blockID: blockID) }
        let excerpt = continuation == nil ? await cloudExcerpt(thread: thread) : nil
        guard !Task.isCancelled, documentSessionID == session else { return }
        let prompt = AmpCloudClient.packagePrompt(instruction: intent.text, excerpt: excerpt)
        updateCloudIntent(intentID) {
            $0.cloudTask?.cloudState = CloudTaskState.inProgress.rawState
            $0.cloudTask?.lastCheckedAt = Date()
        }
        saveNow()

        let outcome = await launchAmpTurn(
            project: ref.repo, prompt: prompt, continuation: continuation, detached: detached,
            onEvent: ampEventHandler(intentID: intentID, session: session)
        )
        guard !Task.isCancelled, documentSessionID == session else {
            // Stopped in this document: `cancelCloudPolling` already marked the turn.
            if documentSessionID == session, ref.paragraphBlockID != nil {
                await editor.setParagraphWorking(step: intent.step, blockID: nil)
            }
            return
        }
        await finishAmpTurn(intentID: intentID, outcome: outcome, session: session)
    }

    private func launchAmpTurn(
        project: String, prompt: String, continuation: String?, detached: Bool,
        onEvent: @escaping @Sendable (AmpStreamEvent) -> Void
    ) async -> AmpTurnOutcome {
        let client = ampClient
        let cwd = projectURL
        do {
            if let continuation {
                return try await client.continueTurn(threadID: continuation, prompt: prompt, cwd: cwd, onEvent: onEvent)
            }
            if detached {
                return try await client.dispatchDetached(project: project, prompt: prompt, cwd: cwd)
            }
            return try await client.streamTurn(project: project, prompt: prompt, cwd: cwd, onEvent: onEvent)
        } catch {
            switch error as? AmpCloudError {
            case .missingBinary?: ampAuthStatus = .missingBinary
            case .credentialUnavailable(let detail)?: ampAuthStatus = .credentialUnavailable(detail)
            default: break
            }
            return .failed(threadID: nil, message: error.localizedDescription)
        }
    }

    private func ampEventHandler(intentID: UUID, session: UUID) -> @Sendable (AmpStreamEvent) -> Void {
        { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.documentSessionID == session else { return }
                    self.applyAmpEvent(event, to: intentID)
                }
            }
        }
    }

    private func applyAmpEvent(_ event: AmpStreamEvent, to intentID: UUID) {
        switch event {
        case .initialized(let threadID):
            updateCloudIntent(intentID) { AmpCloudLifecycle.applyThread(threadID, to: &$0) }
            cloudStreamingIntentIDs.insert(intentID)
            saveNow()
        case .progress(let text):
            cloudLogs[intentID] = AmpCloudLifecycle.appendingProgress(text, to: cloudLogs[intentID])
        case .result, .error, .ignored:
            break
        }
    }

    private func finishAmpTurn(intentID: UUID, outcome: AmpTurnOutcome, session: UUID) async {
        cloudStreamingIntentIDs.remove(intentID)
        guard let index = doc.intents.lastIndex(where: { $0.id == intentID }) else { return }
        let state = AmpCloudLifecycle.apply(outcome, to: &doc.intents[index])
        let intent = doc.intents[index]
        saveNow()
        if intent.cloudTask?.paragraphBlockID != nil {
            await editor.setParagraphWorking(step: intent.step, blockID: nil)
        }
        guard documentSessionID == session else { return }
        if state == .completed, CloudInsertionPlan.shouldAutoInsert(intent: intent) {
            await applyCloudResultToDocument(intentID: intentID, allowEndPreview: false)
            guard documentSessionID == session else { return }
        }
        guard let updated = doc.intents.first(where: { $0.id == intentID }),
              let notification = AmpCloudLifecycle.notificationOutcome(for: updated, state: state) else { return }
        AgentNotifications.shared.coordinator.notify(
            documentURL: fileURL,
            step: updated.step,
            intentID: updated.id,
            threadID: updated.thread,
            outcome: notification,
            wasCancelled: false,
            isDocumentFocused: isDocumentWindowFocused
        )
    }
}

import Foundation
import MarginsCore

extension AppState {
    // MARK: - Instructions

    var busy: Bool { inFlight > 0 }

    func submit(_ raw: String, paragraphBlockID: String? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let config = activeProvider else { lastError = "Choose a model provider."; return }
        previewing = nil
        let step = doc.nextStep
        doc.nextStep += 1
        doc.intents.append(Intent(step: step, text: text, provider: label(config)))
        let documentID = documentSessionID
        let runID = beginRun(step: step, config: config)
        inFlight += 1
        running[step] = Task {
            defer { finish(step, documentID: documentID) }
            if let paragraphBlockID { await editor.setParagraphWorking(step: step, blockID: paragraphBlockID) }
            do {
                try Task.checkCancellation()
                let provider = try provider(for: config)
                let sources = await fetchSources(for: text, step: step)
                try Task.checkCancellation()
                guard documentSessionID == documentID else { return }
                let snapshot = try await editor.blocks()
                guard documentSessionID == documentID else { return }
                if let paragraphBlockID, !snapshot.blocks.contains(where: { $0.id == paragraphBlockID }) {
                    throw ProviderError.protocolError("The prompt paragraph is no longer in the document. Try again from its current location.")
                }
                let agent = agentContext(step: step, kind: config.kind)
                let prompt: String
                if let paragraphBlockID {
                    prompt = PromptBuilder.paragraphPrompt(blocks: forPrompt(snapshot.blocks), blockId: paragraphBlockID,
                                                           instruction: text, sources: sources)
                } else {
                    prompt = PromptBuilder.editPrompt(blocks: forPrompt(snapshot.blocks), instruction: text,
                                                      focus: snapshot.focus, sources: sources)
                }
                let request = GenerationRequest(
                    system: PromptBuilder.system(tools: agent),
                    prompt: prompt,
                    model: config.model.isEmpty ? nil : config.model, agent: agent, reasoningEffort: config.reasoningEffort)
                let before = await projectSnapshot(agent)
                let plan: EditPlan
                do { plan = try await provider.editPlan(request) } catch { await recordProjectChanges(before, step: step, session: documentID); throw error }
                await recordProjectChanges(before, step: step, session: documentID)
                try Task.checkCancellation()
                guard documentSessionID == documentID else { return }
                if paragraphBlockID != nil && plan.edits.isEmpty {
                    throw ProviderError.protocolError("The agent returned no document update. Retry the paragraph prompt.")
                }
                let edits = plan.edits.map { e -> EditOp in var e = e; e.html = doc.internalizeImages(e.html); return e }
                let result = try await editor.apply(step: step, edits: edits, direct: false,
                                                    runID: runID, expectedRevision: snapshot.revision, blockStates: snapshot.blockStates)
                guard documentSessionID == documentID else { return }
                updateIntent(step) {
                    $0.summary = plan.summary
                    let reply = plan.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reply.isEmpty { $0.reply = reply }
                    $0.notes = plan.notes
                    if !result.missing.isEmpty {
                        $0.notes.append("Ignored edits to unknown blocks: \(result.missing.joined(separator: ", "))")
                    }
                    $0.status = result.changes == 0 ? .done : .pending
                    if plan.edits.isEmpty && $0.notes.isEmpty && ($0.reply ?? "").isEmpty && ($0.files ?? []).isEmpty {
                        $0.notes = ["No changes were needed."]
                    }
                }
                let slug = plan.slug.isEmpty ? String(text.prefix(48)) : plan.slug
                finishRun(runID, summary: plan.summary, notes: plan.notes)
                doc.snapshot(html: result.html, slug: slug, author: .agent, detail: text, annotations: result.annotations)
                scheduleSave()
            } catch is CancellationError {
                guard documentSessionID == documentID else { return }
                updateIntent(step) { $0.status = .failed; $0.error = "Stopped." }
                scheduleSave()
            } catch {
                guard documentSessionID == documentID else { return }
                updateIntent(step) { $0.status = .failed; $0.error = Task.isCancelled ? "Stopped." : error.localizedDescription }
                scheduleSave()
            }
            if paragraphBlockID != nil { await editor.setParagraphWorking(step: step, blockID: nil) }
        }
    }

    // MARK: - Inline Discussion

    /// One message in an inline thread about a selected passage. The agent may answer, edit the
    /// selection (as tracked changes for this message's step), or both.
    func discuss(thread: UUID, quote rawQuote: String, focus rawFocus: [String], anchor rawAnchor: String, message raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let config = activeProvider else { lastError = "Choose a model provider."; return }
        previewing = nil
        let prior = doc.intents.filter { $0.kind == .instruction && $0.thread == thread }
        let quote = prior.first?.quote ?? rawQuote
        let focus = prior.first?.focus ?? rawFocus
        let anchor = prior.first?.anchor ?? rawAnchor
        let history = prior.map { p in
            PromptBuilder.ThreadTurn(message: p.text,
                                     reply: p.reply ?? p.error.map { "(no answer: \($0))" } ?? "",
                                     changed: p.status == .pending || p.status == .reviewed ? p.summary : "")
        }
        let step = doc.nextStep
        doc.nextStep += 1
        var intent = Intent(step: step, text: text, provider: label(config))
        intent.thread = thread
        intent.quote = quote
        intent.focus = focus
        intent.anchor = anchor
        doc.intents.append(intent)
        let documentID = documentSessionID
        let runID = beginRun(step: step, config: config)
        inFlight += 1
        running[step] = Task {
            defer { finish(step, documentID: documentID) }
            do {
                let provider = try provider(for: config)
                let sources = await fetchSources(for: text, step: step)
                try Task.checkCancellation()
                guard documentSessionID == documentID else { return }
                let snapshot = try await editor.blocks()
                guard documentSessionID == documentID else { return }
                let live = focus.filter { id in snapshot.blocks.contains { $0.id == id } }
                let agent = agentContext(step: step, kind: config.kind)
                let request = GenerationRequest(
                    system: PromptBuilder.system(tools: agent),
                    prompt: PromptBuilder.discussPrompt(blocks: forPrompt(snapshot.blocks), focus: live.isEmpty ? focus : live,
                                                        quote: quote, history: history, message: text, sources: sources),
                    model: config.model.isEmpty ? nil : config.model, agent: agent, reasoningEffort: config.reasoningEffort)
                let before = await projectSnapshot(agent)
                let plan: EditPlan
                do { plan = try await provider.editPlan(request) } catch { await recordProjectChanges(before, step: step, session: documentID); throw error }
                await recordProjectChanges(before, step: step, session: documentID)
                try Task.checkCancellation()
                guard documentSessionID == documentID else { return }
                var result: EditorBridge.ApplyResult?
                if !plan.edits.isEmpty {
                    let edits = plan.edits.map { e -> EditOp in var e = e; e.html = doc.internalizeImages(e.html); return e }
                    result = try await editor.apply(step: step, edits: edits, direct: false,
                                                    runID: runID, expectedRevision: snapshot.revision, blockStates: snapshot.blockStates)
                    guard documentSessionID == documentID else { return }
                }
                let changed = (result?.changes ?? 0) > 0
                updateIntent(step) {
                    $0.reply = plan.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.summary = changed ? plan.summary : ""
                    $0.notes = plan.notes
                    if let missing = result?.missing, !missing.isEmpty {
                        $0.notes.append("Ignored edits to unknown blocks: \(missing.joined(separator: ", "))")
                    }
                    if ($0.reply ?? "").isEmpty && !changed {
                        $0.reply = plan.summary.isEmpty ? "No changes needed." : plan.summary
                    }
                    $0.status = changed ? .pending : .done
                }
                finishRun(runID, summary: plan.summary, notes: plan.notes)
                if let result, changed {
                    let slug = plan.slug.isEmpty ? String(text.prefix(48)) : plan.slug
                    doc.snapshot(html: result.html, slug: slug, author: .agent, detail: "On “\(quote.prefix(60))”: \(text)", annotations: result.annotations)
                }
                scheduleSave()
            } catch is CancellationError {
                guard documentSessionID == documentID else { return }
                updateIntent(step) { $0.status = .failed; $0.error = "Stopped." }
                scheduleSave()
            } catch {
                guard documentSessionID == documentID else { return }
                updateIntent(step) { $0.status = .failed; $0.error = Task.isCancelled ? "Stopped." : error.localizedDescription }
                scheduleSave()
            }
        }
    }

    func openThread(_ id: UUID) {
        previewing = nil
        Task {
            await editor.endPreview()
            await pushThreads()
            await editor.openThread(id)
        }
    }

    /// Threads change with intents, pending counts, live activity and permission prompts; coalesce pushes.
    func scheduleThreads() {
        guard threadsPush == nil else { return }
        threadsPush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            self.threadsPush = nil
            await self.pushThreads()
        }
    }

    private func pushThreads() async {
        await editor.ready()
        let session = documentSessionID
        let runs = previewing?.annotationRuns ?? doc.annotationRuns
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(runs), let json = String(data: data, encoding: .utf8), json != lastRunsJSON {
            lastRunsJSON = json
            await editor.setAnnotationRuns(runs, availableIntentIDs: Set(doc.intents.map(\.id)))
        }
        guard documentSessionID == session else { return }
        let list = threadPayload()
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != lastThreadsJSON else { return }
        lastThreadsJSON = json
        await editor.setThreads(list)
    }

    private func threadPayload() -> [[String: Any]] {
        var order: [UUID] = []
        var groups: [UUID: [Intent]] = [:]
        for i in doc.intents where i.kind == .instruction {
            guard let t = i.thread else { continue }
            if groups[t] == nil { order.append(t) }
            groups[t, default: []].append(i)
        }
        return order.map { id in
            let items = groups[id] ?? []
            let first = items.first
            return [
                "id": id.uuidString.lowercased(),
                "quote": first?.quote ?? "",
                "anchor": first?.anchor ?? "",
                "focus": first?.focus ?? [],
                "messages": items.map { m -> [String: Any] in
                    [
                        "step": m.step,
                        "text": m.text,
                        "status": m.status.rawValue,
                        "reply": m.reply ?? "",
                        "summary": m.summary,
                        "notes": m.notes,
                        "files": m.files ?? [],
                        "changes": pending.byStep[m.step] ?? 0,
                        "error": m.error ?? "",
                        "waiting": permissionAsks[m.step] != nil,
                        "activity": m.status == .working ? activity(m) : "",
                    ]
                },
            ]
        }
    }

    /// One line describing what the agent is doing right now.
    private func activity(_ m: Intent) -> String {
        if let s = m.steps?.last(where: { $0.status == .running }), !s.title.isEmpty { return s.title }
        if let t = liveThought[m.step]?.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(t.trimmingCharacters(in: .whitespaces).suffix(140))
        }
        return "Thinking…"
    }

    // MARK: - Agent Lifecycle

    /// Fetch what agents can't reliably get themselves (YouTube transcripts), shown as steps on the card.
    /// Failures are recorded on the step; the agent still runs and may find another way.
    private func fetchSources(for text: String, step: Int) async -> [SourceMaterial] {
        let session = documentSessionID
        var out: [SourceMaterial] = []
        for id in YouTube.videoIDs(in: text) {
            guard documentSessionID == session else { return out }
            let url = "https://www.youtube.com/watch?v=\(id)"
            var s = AgentStep(id: "yt-\(id)", kind: .fetch, title: "Fetching YouTube transcript", detail: url)
            apply(.step(s), step: step)
            do {
                let src = try await YouTube.fetch(id: id)
                out.append(src)
                s.title = "YouTube transcript · \(src.wordCount.formatted()) words"
                s.detail = src.title
                s.status = .done
            } catch {
                s.title = "No YouTube transcript"
                s.detail = error.localizedDescription
                s.status = .failed
            }
            guard documentSessionID == session else { return out }
            apply(.step(s), step: step)
            if Task.isCancelled { break }
        }
        return out
    }

    /// Agent context for one instruction: tool policy, the document's workspace, and callbacks
    /// that stream tool calls onto the instruction card. Nil when tools are off or unsupported.
    private func agentContext(step: Int, kind: ProviderKind) -> AgentContext? {
        guard toolPolicy != .off, kind.supportsTools else { return nil }
        updateIntent(step) { if $0.steps == nil { $0.steps = [] } }
        let project = projectURL
        let documentID = documentSessionID
        let runID = activeRunIDs[step]
        return AgentContext(
            policy: toolPolicy,
            workspace: project ?? AgentContext.workspace(for: doc.id),
            project: project != nil,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.documentSessionID == documentID, self.activeRunIDs[step] == runID else { return }
                    self.apply(event, step: step)
                } }
            },
            askPermission: { [weak self] request in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        guard let self, self.documentSessionID == documentID, self.activeRunIDs[step] == runID, self.running[step] != nil else { cont.resume(returning: .deny); return }
                        self.permissionAsks[step] = PermissionAsk(request: request, step: step) { d in cont.resume(returning: d) }
                        self.notifyAgentPermissionNeeded(step: step, request: request)
                    } }
                }
            })
    }

    private func apply(_ event: AgentEvent, step: Int) {
        switch event {
        case .thought(let chunk):
            // Thoughts stream in chunks; show what the agent has said since its last tool call.
            let prior = thoughtBreak.remove(step) == nil ? (liveThought[step] ?? "") : ""
            let text = prior + chunk
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { liveThought[step] = String(text.suffix(600)) }
        case .step(var s):
            updateIntent(step) { intent in
                var steps = intent.steps ?? []
                if let i = steps.firstIndex(where: { $0.id == s.id }) {
                    // Updates often omit fields the start event had.
                    if s.title.isEmpty { s.title = steps[i].title }
                    if s.detail.isEmpty { s.detail = steps[i].detail }
                    if s.kind == .other { s.kind = steps[i].kind }
                    if steps[i].status == .denied { s.status = .denied }
                    steps[i] = s
                } else if !s.title.isEmpty || !s.detail.isEmpty {
                    steps.append(s)
                    thoughtBreak.insert(step)
                }
                intent.steps = steps
            }
            if let runID = activeRunIDs[step], let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) {
                if let i = doc.annotationRuns[index].steps.firstIndex(where: { $0.id == s.id }) {
                    doc.annotationRuns[index].steps[i] = s
                } else { doc.annotationRuns[index].steps.append(s) }
            }
        }
    }

    func answerPermission(step: Int, _ decision: PermissionDecision) {
        guard let ask = permissionAsks.removeValue(forKey: step) else { return }
        ask.resume(decision)
    }

    /// Stop the agent working on an instruction.
    func stop(step: Int) {
        answerPermission(step: step, .deny)
        running[step]?.cancel()
        guard let runID = activeRunIDs[step], let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) else { return }
        doc.annotationRuns[index].status = "failed"
        if !doc.annotationRuns[index].notes.contains("Stopped.") { doc.annotationRuns[index].notes.append("Stopped.") }
        doc.annotationRuns[index].steps = doc.annotationRuns[index].steps.map { var step = $0; if step.status == .running { step.status = .failed }; return step }
        let refining = doc.annotationRuns[index].refinement != nil
        updateIntent(step) { intent in
            intent.status = refining ? .pending : .failed
            if !refining { intent.error = "Stopped." }
            intent.steps = intent.steps?.map { var step = $0; if step.status == .running { step.status = .failed }; return step }
        }
        scheduleSave()
    }

    func stopAll() { running.keys.forEach(stop(step:)) }

    private func finish(_ step: Int, documentID: UUID) {
        guard documentSessionID == documentID else { return }
        answerPermission(step: step, .deny)
        running[step] = nil
        liveThought[step] = nil
        thoughtBreak.remove(step)
        let failed = activeRunIDs[step].flatMap { id in doc.annotationRuns.first { $0.id == id }?.status } == "failed" || doc.intents.first(where: { $0.kind == .instruction && $0.step == step })?.status == .failed
        updateIntent(step) { intent in
            // Anything still "running" when the agent finished didn't report completion.
            intent.steps = intent.steps?.map { var s = $0; if s.status == .running { s.status = failed ? .failed : .done }; return s }
        }
        var finishedRun: AnnotationRun?
        if let runID = activeRunIDs.removeValue(forKey: step), let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) {
            let intent = doc.intents.first { $0.kind == .instruction && $0.step == step }
            if doc.annotationRuns[index].status == "working" { doc.annotationRuns[index].status = intent?.status.rawValue ?? "done" }
            doc.annotationRuns[index].refinements = intent?.refinements ?? []
            if let error = intent?.error, !doc.annotationRuns[index].notes.contains(error) { doc.annotationRuns[index].notes.append(error) }
            doc.annotationRuns[index].steps = doc.annotationRuns[index].steps.map { var s = $0; if s.status == .running { s.status = failed ? .failed : .done }; return s }
            finishedRun = doc.annotationRuns[index]
        }
        notifyAgentRunFinished(step: step, run: finishedRun, failed: failed, cancelled: Task.isCancelled)
        inFlight = max(0, inFlight - 1); scheduleSave()
    }

    private func beginRun(step: Int, config: ProviderConfig, refinement: String? = nil) -> UUID {
        prepareAgentNotifications()
        let intent = doc.intents.first { $0.kind == .instruction && $0.step == step }!
        let parent = refinement == nil ? nil : doc.annotationRuns.last(where: { $0.intentId == intent.id && $0.status != "failed" })?.id
        let run = AnnotationRun(intentId: intent.id, step: step, provider: config.name, model: config.model,
                                instruction: intent.text, refinement: refinement, parentRunId: parent,
                                refinements: intent.refinements)
        doc.annotationRuns.append(run)
        activeRunIDs[step] = run.id
        scheduleSave()
        return run.id
    }

    private func finishRun(_ id: UUID, summary: String, notes: [String]) {
        guard let index = doc.annotationRuns.firstIndex(where: { $0.id == id }) else { return }
        let intent = doc.intents.first { $0.id == doc.annotationRuns[index].intentId }
        doc.annotationRuns[index].summary = summary
        doc.annotationRuns[index].notes = notes
        doc.annotationRuns[index].status = intent?.status.rawValue ?? "done"
        doc.annotationRuns[index].refinements = intent?.refinements ?? []
        doc.annotationRuns[index].steps = doc.annotationRuns[index].steps.map { var s = $0; if s.status == .running { s.status = .done }; return s }
    }

    /// A trusted internal clipboard may bring its original invocation records with it.
    /// Keep those records so subsequent native pushes and version previews preserve them.
    func mergeAnnotationRuns(_ annotations: DocumentAnnotations) {
        guard case .array(let records) = annotations.fields["runs"] else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid annotation date"))
        }
        let encoder = JSONEncoder()
        for record in records {
            guard let data = try? encoder.encode(record), let run = try? decoder.decode(AnnotationRun.self, from: data),
                  !doc.annotationRuns.contains(where: { $0.id == run.id }) else { continue }
            doc.annotationRuns.append(run)
        }
    }

    func captureAnnotations(in body: [String: Any]) -> DocumentAnnotations? {
        guard let annotations = EditorBridge.annotations(in: body) else { return nil }
        mergeAnnotationRuns(annotations)
        return annotations
    }

    func cancelDocumentRuns() {
        documentSessionID = UUID()
        let interrupted = Set(running.keys)
        stopAll()
        for index in doc.intents.indices where interrupted.contains(doc.intents[index].step) && doc.intents[index].status == .working {
            doc.intents[index].status = .failed
            doc.intents[index].error = "Stopped because the document changed."
        }
        for index in doc.annotationRuns.indices where activeRunIDs.values.contains(doc.annotationRuns[index].id) {
            doc.annotationRuns[index].status = "failed"
            doc.annotationRuns[index].notes.append("Stopped because the document changed.")
        }
        running.removeAll()
        activeRunIDs.removeAll()
        inFlight = 0
        liveThought.removeAll()
        thoughtBreak.removeAll()
    }

    func refine(cid: String, instruction: String) {
        guard let config = activeProvider else { return }
        let documentID = documentSessionID
        Task {
            guard let ctx = await editor.refineContext(cid: cid) else { return }
            guard documentSessionID == documentID else { return }
            // One agent run per instruction card at a time.
            guard running[ctx.step] == nil else { await editor.refineFailed(cid: cid); return }
            inFlight += 1
            let prior = doc.intents.first { $0.step == ctx.step }
            updateIntent(ctx.step) { $0.refinements.append(.init(text: instruction)); $0.status = .working; $0.error = nil }
            let runID = beginRun(step: ctx.step, config: config, refinement: instruction)
            running[ctx.step] = Task {
                defer {
                    if documentSessionID == documentID {
                        updateIntent(ctx.step) { if $0.status == .working { $0.status = prior?.status ?? .pending } }
                    }
                    finish(ctx.step, documentID: documentID)
                }
                do {
                    let provider = try provider(for: config)
                    let blockSnapshot = try await editor.blocks()
                    guard documentSessionID == documentID else { return }
                    guard blockSnapshot.blockStates[ctx.blockId] == ctx.blockStates[ctx.blockId] else {
                        throw ProviderError.protocolError("The passage changed before refinement started. Try the refinement again.")
                    }
                    let blocks = forPrompt(blockSnapshot.blocks)
                    let agent = agentContext(step: ctx.step, kind: config.kind)
                    let request = GenerationRequest(
                        system: PromptBuilder.system(tools: agent),
                        prompt: PromptBuilder.refinePrompt(blocks: blocks, blockId: ctx.blockId, original: ctx.original,
                                                           proposed: ctx.proposed, originalInstruction: prior?.text ?? "",
                                                           refinement: instruction),
                        model: config.model.isEmpty ? nil : config.model, agent: agent, reasoningEffort: config.reasoningEffort)
                    let before = await projectSnapshot(agent)
                    let plan: EditPlan
                    do { plan = try await provider.editPlan(request) }
                    catch { await recordProjectChanges(before, step: ctx.step, session: documentID); throw error }
                    await recordProjectChanges(before, step: ctx.step, session: documentID)
                    try Task.checkCancellation()
                    guard documentSessionID == documentID else { return }
                    guard let edit = plan.edits.first(where: { $0.blockId == ctx.blockId }) ?? plan.edits.first else {
                        throw ProviderError.protocolError("The model returned no refinement.")
                    }
                    let count = doc.intents.first { $0.step == ctx.step }?.refinements.count ?? 1
                    guard let result = try await editor.applyRefinement(cid: cid, html: doc.internalizeImages(edit.html), count: count,
                                                                        runID: runID, expectedRevision: ctx.revision, blockStates: ctx.blockStates,
                                                                        parentRunID: doc.annotationRuns.first(where: { $0.id == runID })?.parentRunId) else {
                        throw ProviderError.protocolError("The proposed change is no longer available. Retry from the current change.")
                    }
                    guard documentSessionID == documentID else { return }
                    updateIntent(ctx.step) { $0.status = .pending }
                    finishRun(runID, summary: plan.summary, notes: plan.notes)
                    doc.snapshot(html: result.html, slug: "refined: \(instruction.lowercased().prefix(40))", author: .agent,
                                 detail: prior.map { "Change from “\($0.text)”" } ?? "", annotations: result.annotations)
                    scheduleSave()
                } catch {
                    guard documentSessionID == documentID else { return }
                    await editor.refineFailed(cid: cid)
                    guard documentSessionID == documentID else { return }
                    let msg = (error is CancellationError || Task.isCancelled) ? "Stopped." : error.localizedDescription
                    updateIntent(ctx.step) { $0.notes.append("Refine failed: \(msg)") }
                    if let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) {
                        doc.annotationRuns[index].status = "failed"
                        doc.annotationRuns[index].notes.append(msg)
                    }
                }
            }
        }
    }

    /// Blocks as the model should see them: stored SVG diagrams expanded back to inline `<svg>`.
    private func forPrompt(_ blocks: [Block]) -> [Block] {
        blocks.map { Block(id: $0.id, html: doc.expandSVGForPrompt($0.html), pending: $0.pending) }
    }

    func review(step: Int, accept: Bool) { Task { await editor.resolve(accept: accept, step: step) } }
    func reviewAll(accept: Bool) { Task { await editor.resolve(accept: accept, all: true) } }

    func hover(step: Int?) {
        hoveredStep = step
        Task { await editor.highlight(step: step) }
    }

    func reveal(step: Int) { Task { await editor.reveal(step: step) } }

    func updateIntent(_ step: Int, _ body: (inout Intent) -> Void) {
        guard let i = doc.intents.lastIndex(where: { $0.step == step && $0.kind == .instruction }) else { return }
        body(&doc.intents[i])
    }

    private func label(_ c: ProviderConfig) -> String {
        c.model.isEmpty ? c.name : "\(c.name) · \(c.model)"
    }
}

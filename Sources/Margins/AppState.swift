import AppKit
import Foundation
import MarginsCore
import SwiftUI
import UniformTypeIdentifiers

/// A tool call waiting for the author's go-ahead, shown on its instruction card.
struct PermissionAsk: Identifiable {
    let request: PermissionRequest
    let step: Int
    let resume: (PermissionDecision) -> Void
    var id: String { request.id }
}

struct PendingInfo: Equatable {
    var total = 0
    var byStep: [Int: Int] = [:]
    var selected = 0
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var doc = MarginsDocument() { didSet { scheduleThreads() } }
    @Published private(set) var fileURL: URL
    @Published var pending = PendingInfo() { didSet { scheduleThreads() } }
    @Published var inFlight = 0
    @Published var previewing: Version?
    @Published var showHistory = false
    @Published var showOutline = true {
        didSet {
            defaults.set(showOutline, forKey: "showOutline")
            let on = showOutline
            Task { await editor.setOutline(on) }
        }
    }
    @Published var hoveredStep: Int?
    /// A provenance inspector can reveal the exact instruction that produced a range.
    @Published var revealedIntentID: UUID?
    @Published var instructionRevealRequest = UUID()
    /// What the backend agent may do (web, commands, files). Persisted.
    @Published var toolPolicy: AgentToolPolicy = .research {
        didSet { defaults.set(toolPolicy.rawValue, forKey: "toolPolicy") }
    }
    /// Latest reasoning/narration per working instruction (not persisted).
    @Published var liveThought: [Int: String] = [:] { didSet { scheduleThreads() } }
    /// Tool calls awaiting approval, per instruction step.
    @Published var permissionAsks: [Int: PermissionAsk] = [:] { didSet { scheduleThreads() } }
    private var threadsPush: Task<Void, Never>?
    private var lastThreadsJSON = ""
    private var running: [Int: Task<Void, Never>] = [:]
    private var documentSessionID = UUID()
    private var activeRunIDs: [Int: UUID] = [:]
    private var lastRunsJSON = ""
    /// Steps whose next thought starts a fresh paragraph (a tool call happened since the last one).
    private var thoughtBreak: Set<Int> = []
    @Published var lastError: String?

    @Published var providers: [ProviderConfig] { didSet { persistProviders() } }
    @Published var activeProviderID: UUID { didSet { defaults.set(activeProviderID.uuidString, forKey: "activeProvider") } }
    @Published var models: [UUID: [ModelInfo]] = [:]
    @Published private(set) var zoom: Double = 1.0

    let editor = EditorBridge()
    private var instances: [UUID: (config: ProviderConfig, provider: ModelProvider)] = [:]
    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?

    init(restoreLastDocument: Bool = false, untitledURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let ud = defaults
        var list = ProviderConfig.defaults
        if let data = ud.data(forKey: "providers"),
           let stored = try? JSONDecoder().decode([ProviderConfig].self, from: data), !stored.isEmpty {
            list = stored
        }
        let saved = ud.string(forKey: "activeProvider").flatMap(UUID.init(uuidString:))
        providers = list
        activeProviderID = list.first { $0.id == saved }?.id ?? list.first { $0.enabled }?.id ?? list[0].id
        fileURL = untitledURL ?? Self.newUntitledURL()

        editor.onMessage = { [weak self] type, body in self?.handle(type, body) }
        editor.assetLookup = { [weak self] id in self?.doc.assets[id] }
        editor.onAddAsset = { [weak self] data, mime in self?.doc.addAsset(data, mime: mime) }
        if ud.object(forKey: "showOutline") != nil { showOutline = ud.bool(forKey: "showOutline") }
        if let p = ud.string(forKey: "toolPolicy").flatMap(AgentToolPolicy.init(rawValue:)) { toolPolicy = p }
        let savedZoom = ud.double(forKey: "zoom")
        setZoom(savedZoom > 0 ? savedZoom : 1.0)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: ud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadProviderSettings() }
        }

        if restoreLastDocument, let last = defaults.url(forKey: "lastDocument"), FileManager.default.fileExists(atPath: last.path) {
            open(last)
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    // MARK: - zoom

    private static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ z: Double) {
        zoom = min(max(z, 0.5), 3.0)
        editor.webView.pageZoom = zoom
        defaults.set(zoom, forKey: "zoom")
    }

    // MARK: - providers

    var activeProvider: ProviderConfig? { providers.first { $0.id == activeProviderID } }
    var enabledProviders: [ProviderConfig] { providers.filter(\.enabled) }

    func setModel(_ model: String, for id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[i].model = model
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, for id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }), providers[i].kind == .codex else { return }
        providers[i].reasoningEffort = effort
    }

    private func reloadProviderSettings() {
        guard let data = defaults.data(forKey: "providers"),
              let stored = try? JSONDecoder().decode([ProviderConfig].self, from: data), !stored.isEmpty else { return }
        if providers != stored {
            // Existing runs keep their provider; provider(for:) refreshes changed connections on next use.
            for config in providers where !stored.contains(config) { models[config.id] = nil }
            providers = stored
        }
        let saved = defaults.string(forKey: "activeProvider").flatMap(UUID.init(uuidString:))
        let selected = providers.first { $0.id == saved }?.id ?? providers.first { $0.enabled }?.id ?? providers[0].id
        if selected != activeProviderID { activeProviderID = selected }
    }

    private func persistProviders() {
        if let d = try? JSONEncoder().encode(providers) { defaults.set(d, forKey: "providers") }
    }

    func provider(for config: ProviderConfig) throws -> ModelProvider {
        if let hit = instances[config.id], hit.config.binaryPath == config.binaryPath,
           hit.config.baseURL == config.baseURL, hit.config.kind == config.kind {
            return hit.provider
        }
        instances[config.id]?.provider.shutdown()
        let p = try ProviderFactory.make(config, apiKey: Keychain.get(config.id.uuidString))
        instances[config.id] = (config, p)
        return p
    }

    func invalidate(_ id: UUID) {
        instances[id]?.provider.shutdown()
        instances[id] = nil
        models[id] = nil
    }

    func loadModels(for config: ProviderConfig) async {
        do {
            let list = try await provider(for: config).availableModels()
            models[config.id] = list
        } catch {
            models[config.id] = []
            lastError = error.localizedDescription
        }
    }

    func shutdownProviders() {
        instances.values.forEach { $0.provider.shutdown() }
        instances.removeAll()
    }

    // MARK: - instructions

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

    // MARK: - inline discussion

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
    private func scheduleThreads() {
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

    // MARK: - agent

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
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.documentSessionID == documentID, self.activeRunIDs[step] == runID, self.running[step] != nil else { cont.resume(returning: .deny); return }
                            self.permissionAsks[step] = PermissionAsk(request: request, step: step) { d in cont.resume(returning: d) }
                        }
                    }
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
        let failed = activeRunIDs[step].flatMap { id in doc.annotationRuns.first { $0.id == id }?.status } == "failed"
            || doc.intents.first(where: { $0.kind == .instruction && $0.step == step })?.status == .failed
        updateIntent(step) { intent in
            // Anything still "running" when the agent finished didn't report completion.
            intent.steps = intent.steps?.map { var s = $0; if s.status == .running { s.status = failed ? .failed : .done }; return s }
        }
        if let runID = activeRunIDs.removeValue(forKey: step),
           let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) {
            let intent = doc.intents.first { $0.kind == .instruction && $0.step == step }
            if doc.annotationRuns[index].status == "working" { doc.annotationRuns[index].status = intent?.status.rawValue ?? "done" }
            doc.annotationRuns[index].refinements = intent?.refinements ?? []
            if let error = intent?.error, !doc.annotationRuns[index].notes.contains(error) { doc.annotationRuns[index].notes.append(error) }
            doc.annotationRuns[index].steps = doc.annotationRuns[index].steps.map { var s = $0; if s.status == .running { s.status = failed ? .failed : .done }; return s }
        }
        inFlight = max(0, inFlight - 1)
        scheduleSave()
    }

    private func beginRun(step: Int, config: ProviderConfig, refinement: String? = nil) -> UUID {
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
    private func mergeAnnotationRuns(_ annotations: DocumentAnnotations) {
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

    private func captureAnnotations(in body: [String: Any]) -> DocumentAnnotations? {
        guard let annotations = EditorBridge.annotations(in: body) else { return nil }
        mergeAnnotationRuns(annotations)
        return annotations
    }

    private func cancelDocumentRuns() {
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

    var workspaceURL: URL { projectURL ?? AgentContext.workspace(for: doc.id) }

    func revealWorkspace() { NSWorkspace.shared.activateFileViewerSelecting([workspaceURL]) }

    // MARK: - project folder

    /// The document's project folder, if set and still present.
    var projectURL: URL? {
        guard let p = doc.projectFolder else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    var projectName: String? { doc.projectFolder.map { URL(fileURLWithPath: $0).lastPathComponent } }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Project"
        panel.message = "The agent will work in this folder: it can read it and, with Full agent tools, change files and run commands there."
        if let p = doc.projectFolder { panel.directoryURL = URL(fileURLWithPath: p) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProjectFolder(url)
        if !toolPolicy.canWrite { offerFullAgent(for: url) }
    }

    func setProjectFolder(_ url: URL?) {
        doc.projectFolder = url?.standardizedFileURL.path
        scheduleSave()
    }

    /// Changing files needs Full agent: Codex and Claude can't ask mid-run, so Research is read-only for them.
    private func offerFullAgent(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Let the agent change files in “\(url.lastPathComponent)”?"
        alert.informativeText = """
            Agent tools are set to \(toolPolicy.shortTitle). To write code, edit files and run builds or tests in this \
            project, switch to Full agent. With Research, Copilot asks before each change; Codex and Claude can only read.
            """
        alert.addButton(withTitle: "Use Full Agent")
        alert.addButton(withTitle: "Keep \(toolPolicy.shortTitle)")
        if alert.runModal() == .alertFirstButtonReturn { toolPolicy = .full }
    }

    func openProjectInTerminal() {
        guard let url = projectURL else { return }
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }

    func openProjectFile(_ path: String) {
        guard let root = projectURL else { return }
        let url = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
    }

    /// Snapshot of the project's working tree before an agent run (nil if no project, no tools, or not git).
    private func projectSnapshot(_ agent: AgentContext?) async -> (URL, ProjectChanges.Snapshot)? {
        guard let agent, agent.project else { return nil }
        let dir = agent.workspace
        return await Task.detached { ProjectChanges.snapshot(dir).map { (dir, $0) } }.value
    }

    /// Records which project files the run touched on the intent.
    private func recordProjectChanges(_ before: (URL, ProjectChanges.Snapshot)?, step: Int, session: UUID) async {
        guard documentSessionID == session else { return }
        guard let (dir, snap) = before else { return }
        let files = await Task.detached { ProjectChanges.snapshot(dir).map { ProjectChanges.changed(from: snap, to: $0) } }.value ?? []
        guard documentSessionID == session else { return }
        if let runID = activeRunIDs[step], let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) {
            // Invocation evidence is independent of earlier invocations of this intent.
            doc.annotationRuns[index].files = files
        }
        if !files.isEmpty { updateIntent(step) { $0.files = Array(Set(($0.files ?? []) + files)).sorted() } }
    }

    private func refine(cid: String, instruction: String) {
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

    private func updateIntent(_ step: Int, _ body: (inout Intent) -> Void) {
        guard let i = doc.intents.lastIndex(where: { $0.step == step && $0.kind == .instruction }) else { return }
        body(&doc.intents[i])
    }

    private func label(_ c: ProviderConfig) -> String {
        c.model.isEmpty ? c.name : "\(c.name) · \(c.model)"
    }

    // MARK: - messages from the editor

    private func handle(_ type: String, _ body: [String: Any]) {
        if let session = body["documentSession"] as? String,
           session.lowercased() != documentSessionID.uuidString.lowercased() { return }
        switch type {
        case "ready":
            lastThreadsJSON = ""
            lastRunsJSON = ""
            scheduleThreads()
            let session = documentSessionID
            Task {
                await editor.setOutline(showOutline)
                await loadEditorDocument(session: session)
            }
        case "outline":
            if (body["visible"] as? Bool) == false, showOutline { showOutline = false }
        case "pending":
            var info = PendingInfo()
            info.total = (body["total"] as? NSNumber)?.intValue ?? 0
            info.selected = (body["selected"] as? NSNumber)?.intValue ?? 0
            for (k, v) in body["byStep"] as? [String: Any] ?? [:] {
                if let s = Int(k) { info.byStep[s] = (v as? NSNumber)?.intValue ?? 0 }
            }
            pending = info
            for i in doc.intents.indices where doc.intents[i].kind == .instruction {
                let n = info.byStep[doc.intents[i].step] ?? 0
                if doc.intents[i].status == .pending && n == 0 { doc.intents[i].status = .reviewed }
                else if doc.intents[i].status == .reviewed && n > 0 { doc.intents[i].status = .pending }
            }
        case "edited":
            let html = doc.internalizeImages(body["html"] as? String ?? doc.html)
            let sections = body["sections"] as? [String] ?? []
            let where_ = sections.isEmpty ? "the document" : sections.map { "§\($0)" }.joined(separator: ", ")
            let text = "You edited \(where_)"
            if let last = doc.intents.last, last.kind == .edit, last.text == text {
                doc.intents[doc.intents.count - 1].createdAt = Date()
            } else {
                doc.intents.append(Intent(kind: .edit, step: 0, text: text, status: .done))
            }
            let annotations = captureAnnotations(in: body)
            doc.snapshot(html: html, slug: "edited \(sections.first ?? "document")".lowercased(), author: .you, detail: where_, annotations: annotations)
            scheduleSave()
        case "reviewed":
            let a = (body["accepted"] as? NSNumber)?.intValue ?? 0
            let r = (body["rejected"] as? NSNumber)?.intValue ?? 0
            let sections = body["sections"] as? [String] ?? []
            let parts = [a > 0 ? "accepted \(a)" : nil, r > 0 ? "rejected \(r)" : nil].compactMap { $0 }
            let slug = parts.joined(separator: " · ") + " change\(a + r == 1 ? "" : "s")"
            let annotations = captureAnnotations(in: body)
            doc.snapshot(html: body["html"] as? String ?? doc.html, slug: slug, author: .review,
                         detail: sections.map { "§\($0)" }.joined(separator: ", "), annotations: annotations)
            scheduleSave()
        case "annotations":
            guard previewing == nil, let annotations = captureAnnotations(in: body),
                  let html = body["html"] as? String else { return }
            guard annotations != doc.annotations || html != doc.html else { return }
            doc.snapshot(html: doc.internalizeImages(html), slug: "updated annotations", author: .you,
                         detail: "Local comments and provenance", annotations: annotations)
            scheduleSave()
        case "showAnnotationInstruction", "showIntent":
            let run = (body["runId"] as? String).flatMap(UUID.init(uuidString:)).flatMap { id in
                (previewing?.annotationRuns ?? doc.annotationRuns).first { $0.id == id }
            }
            let id = run?.intentId ?? (body["intentId"] as? String).flatMap(UUID.init(uuidString:))
            if let intent = doc.intents.first(where: {
                $0.id == id || (id == nil && $0.kind == .instruction && $0.step == (body["step"] as? NSNumber)?.intValue)
            }) {
                revealedIntentID = intent.id
                instructionRevealRequest = UUID()
            }
        case "submitParagraph":
            if previewing == nil, let text = body["text"] as? String,
               let blockId = body["blockId"] as? String, !blockId.isEmpty {
                submit(text, paragraphBlockID: blockId)
            }
        case "ask":
            if let t = (body["thread"] as? String).flatMap(UUID.init(uuidString:)), let message = body["message"] as? String {
                discuss(thread: t, quote: body["quote"] as? String ?? "", focus: body["focus"] as? [String] ?? [],
                        anchor: body["anchor"] as? String ?? "", message: message)
            }
        case "stop":
            if let s = body["step"] as? NSNumber { stop(step: s.intValue) }
        case "refine":
            if let cid = body["cid"] as? String, let text = body["instruction"] as? String { refine(cid: cid, instruction: text) }
        default:
            break
        }
    }

    // MARK: - history

    func preview(_ v: Version) {
        if v.id == doc.versions.last?.id { returnToLatest(); return }
        previewing = v
        let session = documentSessionID
        Task {
            guard documentSessionID == session else { return }
            await editor.preview(v.html, annotations: v.annotations)
            guard documentSessionID == session else { return }
            await editor.setAnnotationRuns(v.annotationRuns, availableIntentIDs: Set(doc.intents.map(\.id)))
        }
    }

    func returnToLatest() {
        previewing = nil
        Task {
            await editor.endPreview()
            await editor.setAnnotationRuns(doc.annotationRuns, availableIntentIDs: Set(doc.intents.map(\.id)))
            lastRunsJSON = ""
        }
    }

    func restore(_ v: Version) {
        cancelDocumentRuns()
        previewing = nil
        let session = documentSessionID
        Task {
            guard documentSessionID == session else { return }
            // Preserve the final live edits in history before replacing them.
            await flushAndSave()
            guard documentSessionID == session else { return }
            cancelDocumentRuns()
            saveNow()
            let installedSession = documentSessionID
            await editor.load(v.html, annotations: v.annotations, session: installedSession.uuidString.lowercased())
            guard documentSessionID == installedSession else { return }
            // Keep every historical run resolvable after a restore; current ranges refer only
            // to the restored snapshot. The snapshot's own inspector metadata stays immutable.
            for run in v.annotationRuns where !doc.annotationRuns.contains(where: { $0.id == run.id }) { doc.annotationRuns.append(run) }
            let snapshot = await editor.snapshot()
            guard documentSessionID == installedSession else { return }
            doc.snapshot(html: snapshot?.html ?? v.html, slug: "restored v\(v.number)", author: .you, detail: v.slug,
                         annotations: snapshot?.annotations ?? v.annotations)
            await editor.setAnnotationRuns(doc.annotationRuns, availableIntentIDs: Set(doc.intents.map(\.id)))
            scheduleSave()
        }
    }

    // MARK: - files

    nonisolated static var documentsFolder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Margins")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func newUntitledURL() -> URL { uniqueURL(named: "Untitled") }

    nonisolated static func uniqueURL(named base: String, in dir: URL = documentsFolder) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(MarginsDocument.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(MarginsDocument.fileExtension)
            n += 1
        }
        return url
    }

    func newDocument() {
        cancelDocumentRuns()
        let session = documentSessionID
        let replace = {
            // Work submitted while the outgoing WebKit snapshot was draining
            // belongs to that outgoing document too.
            self.cancelDocumentRuns()
            self.saveNow()
            self.doc = MarginsDocument()
            self.fileURL = Self.newUntitledURL()
            self.previewing = nil
            self.pending = PendingInfo()
            self.defaults.removeObject(forKey: "lastDocument")
            let installedSession = self.documentSessionID
            Task { await self.loadEditorDocument(session: installedSession) }
        }
        if editor.isReadyForSnapshot {
            Task {
                await flushAndSave()
                guard documentSessionID == session else { return }
                replace()
            }
        } else {
            saveNow()
            replace()
        }
    }

    func open(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var d = try MarginsDocument.decode(data)
            let hadID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] != nil
            d.pruneAssets()
            cancelDocumentRuns()
            let session = documentSessionID
            let replace = { (document: MarginsDocument) in
                let reopeningCurrent = self.fileURL.standardizedFileURL == url.standardizedFileURL
                self.cancelDocumentRuns()
                self.saveNow()
                let incoming = reopeningCurrent ? ((try? MarginsDocument.decode(Data(contentsOf: url))) ?? document) : document
                self.doc = incoming
                self.fileURL = url
                self.previewing = nil
                self.pending = PendingInfo()
                self.defaults.set(url, forKey: "lastDocument")
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                let installedSession = self.documentSessionID
                Task { await self.loadEditorDocument(session: installedSession) }
                if !incoming.versions.isEmpty { self.writeMarkdown() }
                if !hadID { self.scheduleSave() }
            }
            if editor.isReadyForSnapshot {
                Task {
                    await flushAndSave()
                    guard documentSessionID == session else { return }
                    do {
                        // Reopening the same file must include edits just drained above.
                        var current = try MarginsDocument.decode(Data(contentsOf: url))
                        current.pruneAssets()
                        replace(current)
                    } catch { lastError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)" }
                }
            } else {
                saveNow()
                replace(d)
            }
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Load HTML and its matching annotation state together, then persist any conservative
    /// legacy migration performed by the editor (old text starts unattributed).
    private func loadEditorDocument(session: UUID) async {
        guard documentSessionID == session else { return }
        let html = doc.html
        let annotations = doc.annotations
        await editor.ready()
        guard documentSessionID == session else { return }
        await editor.load(html, annotations: annotations, session: session.uuidString.lowercased())
        guard documentSessionID == session else { return }
        if let snapshot = await editor.snapshot(), documentSessionID == session {
            doc.html = snapshot.html
            doc.annotations = snapshot.annotations
            mergeAnnotationRuns(snapshot.annotations)
            if !html.isEmpty { scheduleSave() }
        }
        await editor.setAnnotationRuns(doc.annotationRuns, availableIntentIDs: Set(doc.intents.map(\.id)))
        lastRunsJSON = ""
    }

    /// Drain author edits, review timers, and local comments as one HTML/metadata pair.
    /// This also works while history is open: the editor returns its saved live state.
    func flushAndSave(includeEmpty: Bool = false) async {
        let session = documentSessionID
        if editor.isReadyForSnapshot {
            await editor.flushForSave()
            guard documentSessionID == session else { return }
            if let snapshot = await editor.snapshot(), documentSessionID == session {
                let html = doc.internalizeImages(snapshot.html)
                mergeAnnotationRuns(snapshot.annotations)
                var currentFields = doc.annotations.fields
                var snapshotFields = snapshot.annotations.fields
                currentFields.removeValue(forKey: "runs")
                snapshotFields.removeValue(forKey: "runs")
                if html != doc.html || snapshotFields != currentFields {
                    doc.snapshot(html: html, slug: "saved edits", author: .you, annotations: snapshot.annotations)
                } else { doc.annotations = snapshot.annotations }
            }
        }
        guard documentSessionID == session else { return }
        saveNow(includeEmpty: includeEmpty)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: MarginsDocument.fileExtension) ?? .json]
        panel.directoryURL = Self.documentsFolder
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func showSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: MarginsDocument.fileExtension) ?? .json]
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            let session = documentSessionID
            Task {
                await flushAndSave()
                guard documentSessionID == session else { return }
                let old = fileURL
                fileURL = url
                saveNow()
                if old != url, isUntitled(old) {
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("md"))
                }
            }
        }
    }

    func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = doc.title + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let blocks = (try? await editor.blocks().blocks) ?? []
            let body = doc.inliningAssets(blocks.map(\.html).joined(separator: "\n"))
            let page = "<!doctype html><meta charset=utf-8><title>\(doc.title)</title>\n<body style=\"max-width:720px;margin:40px auto;font:16px/1.6 -apple-system,sans-serif\">\n\(body)\n</body>"
            try? page.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

    private func isUntitled(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == Self.documentsFolder.standardizedFileURL
            && url.lastPathComponent.hasPrefix("Untitled")
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow(includeEmpty: Bool = false) {
        saveTask?.cancel()
        guard includeEmpty || !doc.versions.isEmpty || !doc.intents.isEmpty else { return }
        // Name untitled docs after their title once they have one.
        if isUntitled(fileURL), doc.title != "Untitled" {
            let safe = doc.title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(80)
            let newURL = Self.uniqueURL(named: String(safe))
            if FileManager.default.fileExists(atPath: fileURL.path) { try? FileManager.default.moveItem(at: fileURL, to: newURL) }
            try? FileManager.default.removeItem(at: markdownURL)
            try? FileManager.default.removeItem(at: assetsFolderURL)
            fileURL = newURL
        }
        do {
            try doc.encoded().write(to: fileURL, options: .atomic)
            defaults.set(fileURL, forKey: "lastDocument")
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
            return
        }
        writeMarkdown()
    }

    /// Plain-Markdown mirror of the current accepted text, kept next to the `.margins` file.
    var markdownURL: URL { fileURL.deletingPathExtension().appendingPathExtension("md") }

    /// `<Title>.assets/`, holding the images the Markdown mirror points at.
    var assetsFolderURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("assets")
    }

    private func writeMarkdown() {
        let folder = assetsFolderURL
        let folderName = folder.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.lastPathComponent
        let used = MarginsDocument.assetIDs(in: doc.html).filter { doc.assets[$0] != nil }
        syncAssetFolder(folder, ids: used)
        let md = MarkdownExporter.markdown(fromHTML: doc.html) { [doc] src in
            guard let id = MarginsDocument.assetID(fromSrc: src), let a = doc.assets[id] else { return src }
            return "\(folderName)/\(id).\(a.fileExtension)"
        }
        let url = markdownURL
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == md { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn't write Markdown: \(error.localizedDescription)"
        }
    }

    private func syncAssetFolder(_ folder: URL, ids: Set<String>) {
        let fm = FileManager.default
        guard !ids.isEmpty else { try? fm.removeItem(at: folder); return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let wanted = Dictionary(uniqueKeysWithValues: ids.compactMap { id in doc.assets[id].map { ("\(id).\($0.fileExtension)", $0) } })
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where wanted[name] == nil {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        for (name, asset) in wanted where !fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            try? asset.data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    func insertImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .svg]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url),
                      let mime = Asset.mime(forExtension: url.pathExtension) ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                      mime.hasPrefix("image/") else { continue }
                let src = doc.addAsset(data, mime: mime)
                await editor.insertImage(src: src, alt: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    func editLink() { Task { await editor.editLink() } }

    func revealMarkdown() {
        Task {
            await flushAndSave()
            NSWorkspace.shared.activateFileViewerSelecting([markdownURL])
        }
    }
}

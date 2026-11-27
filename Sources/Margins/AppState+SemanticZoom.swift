import AppKit
import Foundation
import MarginsCore

extension AppState {
    var canSemanticZoom: Bool { semanticZoomSourceWordCount >= 200 && !busy && activeProvider != nil }

    func refreshSemanticZoomWordCount() {
        semanticZoomSourceWordCount = SemanticZoom.liveWordCount(in: doc.html)
    }

    func stepSemanticZoom(shorter: Bool) {
        let stops = SemanticZoomStop.allCases.sorted { $0.rawValue > $1.rawValue }
        guard let index = stops.firstIndex(of: semanticZoomStop) else { return }
        let next = min(max(index + (shorter ? 1 : -1), 0), stops.count - 1)
        setSemanticZoom(stops[next])
    }

    func setSemanticZoom(_ stop: SemanticZoomStop) {
        if stop == .full { cancelSemanticZoom(); return }
        guard canSemanticZoom, let config = activeProvider else { return }
        if stop == semanticZoomStop && semanticZoomError == nil { return }
        semanticZoomTask?.cancel()
        let requestID = UUID(), session = documentSessionID
        semanticZoomRequestID = requestID
        semanticZoomStop = stop
        semanticZoomLoading = true
        semanticZoomError = nil
        semanticZoomStatus = nil
        semanticZoomStartedAt = Date()
        semanticZoomTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.generateSemanticZoom(stop, config: config, requestID: requestID, session: session)
            } catch {
                guard self.semanticZoomIsCurrent(requestID, session: session) else { return }
                self.semanticZoomLoading = false
                self.semanticZoomStartedAt = nil
                if !(error is CancellationError) { self.semanticZoomError = error.localizedDescription }
            }
        }
    }

    private func semanticZoomIsCurrent(_ requestID: UUID, session: UUID) -> Bool {
        semanticZoomRequestID == requestID && documentSessionID == session && !Task.isCancelled
    }

    private func generateSemanticZoom(_ stop: SemanticZoomStop, config: ProviderConfig,
                                      requestID: UUID, session: UUID) async throws {
        let anchor = await editor.visibleAnchorHeading() ?? semanticZoomAnchorHeading
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        semanticZoomAnchorHeading = anchor
        await flushAndSave()
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        guard let source = await editor.snapshot()?.html else {
            throw ProviderError.protocolError("Couldn't read the document. Try again.")
        }
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        semanticZoomSourceWordCount = SemanticZoom.liveWordCount(in: source)
        guard semanticZoomSourceWordCount >= 200 else { cancelSemanticZoom(); return }
        let key = SemanticZoomCache.Key(documentHash: SemanticZoom.documentHash(for: source), stopPercentage: stop.rawValue,
                                        providerID: config.id.uuidString, modelID: config.model)
        previewing = nil
        await editor.endPreview()
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        await editor.setSemanticZoom(html: semanticZoomHTML ?? "", stop: stop.rawValue, anchorHeading: anchor)
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        let html: String
        if let cached = semanticZoomCache.value(for: key) {
            html = cached
        } else {
            let agent = semanticZoomAgent(requestID: requestID, session: session)
            let request = GenerationRequest(
                system: SemanticZoomPromptBuilder.system,
                prompt: SemanticZoomPromptBuilder.prompt(html: source, stop: stop),
                model: config.model.isEmpty ? nil : config.model, agent: agent,
                reasoningEffort: config.kind == .codex ? .low : config.reasoningEffort, outputSchema: nil)
            let generated = try await provider(for: config).generate(request)
            guard semanticZoomIsCurrent(requestID, session: session) else { return }
            html = try SemanticZoomHTMLSanitizer.sanitize(generated)
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderError.protocolError("The agent returned an empty summary. Try regenerating.")
            }
            semanticZoomCache.insert(html, for: key)
        }
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        await editor.setSemanticZoom(html: html, stop: stop.rawValue, anchorHeading: anchor)
        guard semanticZoomIsCurrent(requestID, session: session) else { return }
        semanticZoomHTML = html
        semanticZoomWordCount = SemanticZoom.liveWordCount(in: html)
        semanticZoomLoading = false
        semanticZoomStartedAt = nil
        semanticZoomStatus = nil
        semanticZoomTask = nil
    }

    private func semanticZoomAgent(requestID: UUID, session: UUID) -> AgentContext {
        AgentContext(policy: .off, workspace: fileURL.deletingLastPathComponent(), onEvent: { [weak self] event in
            guard case .thought(let text) = event else { return }
            Task { @MainActor [weak self] in
                guard let self, self.semanticZoomIsCurrent(requestID, session: session),
                      self.semanticZoomLoading else { return }
                self.semanticZoomStatus = String(text.suffix(300))
            }
        })
    }

    func cancelSemanticZoom(scrollToBlockId: String? = nil, anchorHeading: String? = nil) {
        semanticZoomTask?.cancel()
        semanticZoomTask = nil
        let requestID = UUID()
        semanticZoomRequestID = requestID
        semanticZoomStop = .full
        semanticZoomLoading = false
        semanticZoomStartedAt = nil
        semanticZoomStatus = nil
        semanticZoomError = nil
        semanticZoomHTML = nil
        semanticZoomWordCount = 0
        semanticZoomAnchorHeading = nil
        Task {
            guard semanticZoomRequestID == requestID else { return }
            await editor.clearSemanticZoom(scrollToBlockId: scrollToBlockId, anchorHeading: anchorHeading)
        }
    }

    func regenerateSemanticZoom() {
        let stop = semanticZoomStop
        guard stop != .full else { return }
        semanticZoomCache.removeAll()
        semanticZoomError = "Regenerating"
        setSemanticZoom(stop)
    }

    func handleSemanticZoomMessage(_ type: String, _ body: [String: Any]) -> Bool {
        if type == "liveWordCount" {
            semanticZoomSourceWordCount = (body["wordCount"] as? NSNumber)?.intValue ?? semanticZoomSourceWordCount
            return true
        }
        if type == "semanticZoomSource" {
            guard semanticZoomStop != .full else { return true }
            cancelSemanticZoom(scrollToBlockId: body["blockId"] as? String, anchorHeading: body["heading"] as? String)
            return true
        }
        guard semanticZoomStop != .full else { return false }
        return ["edited", "reviewed", "annotations", "submitParagraph", "ask", "refine", "pending"].contains(type)
    }

    func prepareForDocumentInstruction() {
        cancelSemanticZoom()
        previewing = nil
    }

    func instructionBlocks() async throws -> EditorBridge.BlocksResult {
        await editor.clearSemanticZoom()
        await editor.endPreview()
        return try await editor.blocks()
    }

    func instructionRefineContext(cid: String) async -> EditorBridge.RefineContext? {
        prepareForDocumentInstruction()
        await editor.clearSemanticZoom()
        await editor.endPreview()
        return await editor.refineContext(cid: cid)
    }
}

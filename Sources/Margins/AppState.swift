import AppKit
import Foundation
import MarginsCore
import SwiftUI

struct PendingInfo: Equatable {
    var total = 0
    var byStep: [Int: Int] = [:]
    var selected = 0
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var doc = MarginsDocument()
    @Published private(set) var fileURL: URL
    @Published var pending = PendingInfo()
    @Published var inFlight = 0
    @Published var previewing: Version?
    @Published var showHistory = false
    @Published var hoveredStep: Int?
    @Published var lastError: String?

    @Published var providers: [ProviderConfig] { didSet { persistProviders() } }
    @Published var activeProviderID: UUID { didSet { defaults.set(activeProviderID.uuidString, forKey: "activeProvider") } }
    @Published var models: [UUID: [ModelInfo]] = [:]
    @Published private(set) var zoom: Double = 1.0

    let editor = EditorBridge()
    private var instances: [UUID: (config: ProviderConfig, provider: ModelProvider)] = [:]
    private let defaults = UserDefaults.standard
    private var saveTask: Task<Void, Never>?

    private init() {
        let ud = UserDefaults.standard
        var list = ProviderConfig.defaults
        if let data = ud.data(forKey: "providers"),
           let stored = try? JSONDecoder().decode([ProviderConfig].self, from: data), !stored.isEmpty {
            list = stored
        }
        let saved = ud.string(forKey: "activeProvider").flatMap(UUID.init(uuidString:))
        providers = list
        activeProviderID = list.first { $0.id == saved }?.id ?? list.first { $0.enabled }?.id ?? list[0].id
        fileURL = Self.newUntitledURL()

        editor.onMessage = { [weak self] type, body in self?.handle(type, body) }
        let savedZoom = ud.double(forKey: "zoom")
        setZoom(savedZoom > 0 ? savedZoom : 1.0)

        if let last = defaults.url(forKey: "lastDocument"), FileManager.default.fileExists(atPath: last.path) {
            open(last)
        }
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

    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let config = activeProvider else { lastError = "Choose a model provider."; return }
        previewing = nil
        let step = doc.nextStep
        doc.nextStep += 1
        doc.intents.append(Intent(step: step, text: text, provider: label(config)))
        inFlight += 1
        Task {
            defer { inFlight -= 1 }
            do {
                let provider = try provider(for: config)
                let snapshot = try await editor.blocks()
                let request = GenerationRequest(
                    system: PromptBuilder.system,
                    prompt: PromptBuilder.editPrompt(blocks: snapshot.blocks, instruction: text, focus: snapshot.focus),
                    model: config.model.isEmpty ? nil : config.model)
                let plan = try await provider.editPlan(request)
                let direct = snapshot.blocks.isEmpty
                let result = try await editor.apply(step: step, edits: plan.edits, direct: direct)
                updateIntent(step) {
                    $0.summary = plan.summary
                    $0.notes = plan.notes
                    if !result.missing.isEmpty {
                        $0.notes.append("Ignored edits to unknown blocks: \(result.missing.joined(separator: ", "))")
                    }
                    $0.status = (direct || result.changes == 0) ? .done : .pending
                    if plan.edits.isEmpty && $0.notes.isEmpty { $0.notes = ["No changes were needed."] }
                }
                let slug = plan.slug.isEmpty ? String(text.prefix(48)) : plan.slug
                doc.snapshot(html: result.html, slug: slug, author: .agent, detail: text)
                scheduleSave()
            } catch {
                updateIntent(step) { $0.status = .failed; $0.error = error.localizedDescription }
                scheduleSave()
            }
        }
    }

    private func refine(cid: String, instruction: String) {
        guard let config = activeProvider else { return }
        inFlight += 1
        Task {
            defer { inFlight -= 1 }
            guard let ctx = await editor.refineContext(cid: cid) else { return }
            let original = doc.intents.first { $0.step == ctx.step }
            updateIntent(ctx.step) { $0.refinements.append(.init(text: instruction)) }
            do {
                let provider = try provider(for: config)
                let blocks = try await editor.blocks().blocks
                let plan = try await provider.editPlan(GenerationRequest(
                    system: PromptBuilder.system,
                    prompt: PromptBuilder.refinePrompt(blocks: blocks, blockId: ctx.blockId, original: ctx.original,
                                                       proposed: ctx.proposed, originalInstruction: original?.text ?? "",
                                                       refinement: instruction),
                    model: config.model.isEmpty ? nil : config.model))
                guard let edit = plan.edits.first(where: { $0.blockId == ctx.blockId }) ?? plan.edits.first else {
                    throw ProviderError.protocolError("The model returned no refinement.")
                }
                let count = doc.intents.first { $0.step == ctx.step }?.refinements.count ?? 1
                if let html = await editor.applyRefinement(cid: cid, html: edit.html, count: count) {
                    doc.snapshot(html: html, slug: "refined: \(instruction.lowercased().prefix(40))", author: .agent,
                                 detail: original.map { "Change from “\($0.text)”" } ?? "")
                    scheduleSave()
                }
            } catch {
                await editor.refineFailed(cid: cid)
                updateIntent(ctx.step) { $0.notes.append("Refine failed: \(error.localizedDescription)") }
            }
        }
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
        switch type {
        case "ready":
            Task { await editor.load(doc.html) }
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
            let html = body["html"] as? String ?? doc.html
            let sections = body["sections"] as? [String] ?? []
            let where_ = sections.isEmpty ? "the document" : sections.map { "§\($0)" }.joined(separator: ", ")
            let text = "You edited \(where_)"
            if let last = doc.intents.last, last.kind == .edit, last.text == text {
                doc.intents[doc.intents.count - 1].createdAt = Date()
            } else {
                doc.intents.append(Intent(kind: .edit, step: 0, text: text, status: .done))
            }
            doc.snapshot(html: html, slug: "edited \(sections.first ?? "document")".lowercased(), author: .you, detail: where_)
            scheduleSave()
        case "reviewed":
            let a = (body["accepted"] as? NSNumber)?.intValue ?? 0
            let r = (body["rejected"] as? NSNumber)?.intValue ?? 0
            let sections = body["sections"] as? [String] ?? []
            let parts = [a > 0 ? "accepted \(a)" : nil, r > 0 ? "rejected \(r)" : nil].compactMap { $0 }
            let slug = parts.joined(separator: " · ") + " change\(a + r == 1 ? "" : "s")"
            doc.snapshot(html: body["html"] as? String ?? doc.html, slug: slug, author: .review,
                         detail: sections.map { "§\($0)" }.joined(separator: ", "))
            scheduleSave()
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
        Task { await editor.preview(v.html) }
    }

    func returnToLatest() {
        previewing = nil
        Task { await editor.endPreview() }
    }

    func restore(_ v: Version) {
        previewing = nil
        Task {
            await editor.load(v.html)
            doc.snapshot(html: v.html, slug: "restored v\(v.number)", author: .you, detail: v.slug)
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
        saveNow()
        doc = MarginsDocument()
        fileURL = Self.newUntitledURL()
        previewing = nil
        pending = PendingInfo()
        defaults.removeObject(forKey: "lastDocument")
        Task { await editor.load("") }
    }

    func open(_ url: URL) {
        do {
            let d = try MarginsDocument.decode(Data(contentsOf: url))
            saveNow()
            doc = d
            fileURL = url
            previewing = nil
            defaults.set(url, forKey: "lastDocument")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            Task { await editor.load(d.html) }
            if !d.versions.isEmpty { writeMarkdown() }
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
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
            let old = fileURL
            fileURL = url
            saveNow()
            if old != url, isUntitled(old) {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("md"))
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
            let body = blocks.map(\.html).joined(separator: "\n")
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

    func saveNow() {
        saveTask?.cancel()
        guard !doc.versions.isEmpty || !doc.intents.isEmpty else { return }
        // Name untitled docs after their title once they have one.
        if isUntitled(fileURL), doc.title != "Untitled" {
            let safe = doc.title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(80)
            let newURL = Self.uniqueURL(named: String(safe))
            if FileManager.default.fileExists(atPath: fileURL.path) { try? FileManager.default.moveItem(at: fileURL, to: newURL) }
            try? FileManager.default.removeItem(at: markdownURL)
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

    private func writeMarkdown() {
        let md = MarkdownExporter.markdown(fromHTML: doc.html)
        let url = markdownURL
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == md { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn't write Markdown: \(error.localizedDescription)"
        }
    }

    func revealMarkdown() {
        saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([markdownURL])
    }
}

import AppKit
import Foundation
import MarginsCore
import UniformTypeIdentifiers

extension AppState {
    // MARK: - Messages from the Editor

    func handle(_ type: String, _ body: [String: Any]) {
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
                await editor.setCloudMode(composerTarget == .cloud)
                await editor.setFonts(document: fontPreferences.documentFontCSS, ui: fontPreferences.uiFontCSS)
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
                routeParagraphPrompt(text, blockID: blockId)
            }
        case "ask":
            routeThreadMessage(body)
        case "stop":
            if let s = body["step"] as? NSNumber { stop(step: s.intValue) }
        case "refine":
            if let cid = body["cid"] as? String, let text = body["instruction"] as? String { refine(cid: cid, instruction: text) }
        default:
            break
        }
    }

    // MARK: - History

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

    // MARK: - Files

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
            self.startWatchingCurrentFile()
            self.previewing = nil
            self.pending = PendingInfo()
            self.defaults.removeObject(forKey: "lastDocument")
            self.refreshCloudContext(forceRepoResolve: true)
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

    private func readDocument(at url: URL) throws -> (document: MarginsDocument, needsIDSave: Bool) {
        if SyncController.shared.isInSyncedLibrary(url) {
            let file = try SyncDocument.load(at: url, index: SyncController.shared.index)
            return (file.document, false)
        }
        let data = try Data(contentsOf: url)
        let doc = try MarginsDocument.decode(data)
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (doc, fields?["id"] == nil)
    }

    func open(_ url: URL) {
        do {
            let loaded = try readDocument(at: url)
            var d = loaded.document
            d.pruneAssets()
            cancelDocumentRuns()
            let session = documentSessionID
            let replace = { (document: MarginsDocument) in
                let reopeningCurrent = self.fileURL.standardizedFileURL == url.standardizedFileURL
                self.cancelDocumentRuns()
                self.saveNow()
                let incoming = reopeningCurrent ? ((try? self.readDocument(at: url).document) ?? document) : document
                self.doc = incoming
                self.projectFolderStore.migrateIfNeeded(docID: incoming.id, legacyFolder: incoming.projectFolder)
                self.projectFolderRevision += 1
                self.fileURL = url
                self.startWatchingCurrentFile()
                self.resumeCloudPolling()
                self.refreshCloudContext(forceRepoResolve: true)
                self.previewing = nil
                self.pending = PendingInfo()
                self.defaults.set(url, forKey: "lastDocument")
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                let installedSession = self.documentSessionID
                Task { await self.loadEditorDocument(session: installedSession) }
                if !incoming.versions.isEmpty { self.writeMarkdown() }
                if loaded.needsIDSave { self.scheduleSave() }
            }
            if editor.isReadyForSnapshot {
                Task {
                    await flushAndSave()
                    guard documentSessionID == session else { return }
                    do {
                        // Reopening the same file must include edits just drained above.
                        var current = try readDocument(at: url).document
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
    func loadEditorDocument(session: UUID) async {
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

    func startWatchingCurrentFile() {
        let watcher = fileWatcher ?? FileChangeWatcher { [weak self] url in
            Task { @MainActor [weak self] in
                self?.reloadFromExternalChange(url)
            }
        }
        fileWatcher = watcher
        watcher.watch(fileURL)
    }

    func reloadFromExternalChange(_ url: URL) {
        guard url.standardizedFileURL == fileURL.standardizedFileURL else { return }
        guard !busy, previewing == nil else { return }
        guard var incoming = try? readDocument(at: url).document else { return }
        incoming.pruneAssets()
        guard incoming != doc else { return }
        doc = incoming
        projectFolderStore.migrateIfNeeded(docID: incoming.id, legacyFolder: incoming.projectFolder)
        projectFolderRevision += 1
        resumeCloudPolling()
        pending = PendingInfo()
        let session = documentSessionID
        Task { await loadEditorDocument(session: session) }
        if !incoming.versions.isEmpty { writeMarkdown() }
    }

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
            startWatchingCurrentFile()
        }
        do {
            let encoded = try doc.encoded()
            fileWatcher?.markSelfWrite(encoded)
            try encoded.write(to: fileURL, options: .atomic)
            defaults.set(fileURL, forKey: "lastDocument")
            SyncController.shared.schedulePush(for: fileURL)
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

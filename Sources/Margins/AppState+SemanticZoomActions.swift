import AppKit
import Foundation
import MarginsCore

extension AppState {
    private var promotableSemanticZoomHTML: String? {
        guard semanticZoomStop != .full, !semanticZoomLoading, semanticZoomError == nil,
              let html = semanticZoomHTML else { return nil }
        return try? SemanticZoomHTMLSanitizer.sanitize(html, forPromotion: true)
    }

    func copySemanticZoomMarkdown() {
        guard let html = promotableSemanticZoomHTML else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownExporter.markdown(fromHTML: html), forType: .string)
    }

    func copySemanticZoomRichText() {
        guard let html = promotableSemanticZoomHTML else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        let text = (try? NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil))?.string ?? MarkdownExporter.markdown(fromHTML: html)
        pasteboard.setString(text, forType: .string)
    }

    func replaceWithSemanticZoom() {
        guard let html = promotableSemanticZoomHTML else { return }
        let stop = semanticZoomStop, session = documentSessionID
        cancelSemanticZoom()
        Task {
            await editor.clearSemanticZoom()
            await flushAndSave()
            guard documentSessionID == session, !busy, semanticZoomStop == .full else { return }
            cancelDocumentRuns()
            let installedSession = documentSessionID
            if doc.versions.last?.html != doc.html {
                doc.snapshot(html: doc.html, slug: "before summary", author: .you)
            }
            doc.snapshot(html: html, slug: "\(stop.rawValue)% summary", author: .you,
                         detail: "Promoted semantic zoom summary", annotations: DocumentAnnotations())
            pending = PendingInfo()
            await loadEditorDocument(session: installedSession)
            guard documentSessionID == installedSession else { return }
            saveNow()
        }
    }

    func duplicateSemanticZoom() {
        guard let html = promotableSemanticZoomHTML else { return }
        do {
            var duplicate = MarginsDocument(html: html)
            duplicate.assets = doc.assets
            duplicate.snapshot(html: html, slug: "\(semanticZoomStop.rawValue)% summary", author: .you,
                               detail: "Duplicated from \(doc.title)")
            duplicate.pruneAssets()
            let url = Self.uniqueURL(named: "\(doc.title) — Summary")
            try duplicate.encoded().write(to: url, options: .atomic)
            DocumentWindows.shared.open(url)
        } catch {
            semanticZoomError = "Couldn't duplicate summary: \(error.localizedDescription)"
        }
    }
}

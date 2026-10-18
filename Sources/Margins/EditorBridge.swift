import AppKit
import SwiftUI
import WebKit
import MarginsCore

/// Owns the WKWebView that hosts the tracked-changes editor and exposes a typed async API over it.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onMessage: ((String, [String: Any]) -> Void)?
    /// Resolves `margins-asset://img/<id>.<ext>` for the web view.
    var assetLookup: ((String) -> Asset?)? {
        get { assetHandler.lookup }
        set { assetHandler.lookup = newValue }
    }
    /// Stores pasted/dropped image bytes and returns their `margins-asset://` URL.
    var onAddAsset: ((Data, String) -> String?)?
    private var isReady = false
    var isReadyForSnapshot: Bool { isReady }
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private let assetHandler = AssetSchemeHandler()

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        config.setURLSchemeHandler(assetHandler, forURLScheme: MarginsDocument.assetScheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(WeakHandler(self), name: "margins")
        controller.addScriptMessageHandler(AssetUploadHandler(self), contentWorld: .page, name: "assets")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        if let dir = Self.editorDirectory {
            webView.loadFileURL(dir.appendingPathComponent("editor.html"), allowingReadAccessTo: dir)
        }
    }

    /// Finds `Editor/` inside the SwiftPM resource bundle, whether running from `swift run`
    /// (bundle next to the binary) or from the packaged Margins.app (bundle in Contents/Resources).
    static var editorDirectory: URL? {
        let name = "Margins_Margins.bundle"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name)) }
        for c in candidates {
            var roots = [c, c.appendingPathComponent("Contents/Resources")]
            if let r = Bundle(url: c)?.resourceURL { roots.insert(r, at: 0) }
            for root in roots {
                let dir = root.appendingPathComponent("Editor")
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("editor.html").path) { return dir }
            }
        }
        NSLog("Margins: editor resources not found in %@", candidates.map(\.path).joined(separator: ", "))
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "openURL" {
            if let s = body["url"] as? String, let url = URL(string: s), Self.openableSchemes.contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if type == "ready" {
            isReady = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters.removeAll()
        }
        onMessage?(type, body)
    }

    func ready() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    @discardableResult
    func call(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        await ready()
        return try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
    }

    // MARK: typed API

    func load(_ html: String, annotations: DocumentAnnotations = DocumentAnnotations(), session: String? = nil) async {
        _ = try? await call("return window.margins.load(html, annotations, session)",
                            ["html": html, "annotations": Self.jsonObject(annotations), "session": session.map { $0 as Any } ?? NSNull()])
    }

    /// Deliver pending debounced edit/review events before the final save on Quit.
    func flushForSave() async {
        guard isReady else { return }
        _ = try? await call("window.margins.flushForSave()")
    }

    func html() async -> String? {
        try? await call("return window.margins.html()") as? String
    }

    struct BlocksResult { var blocks: [Block]; var focus: [String]; var revision: Int }

    func blocks() async throws -> BlocksResult {
        let r = try await call("return window.margins.getBlocks()") as? [String: Any] ?? [:]
        let blocks = (r["blocks"] as? [[String: Any]] ?? []).compactMap { d -> Block? in
            guard let id = d["id"] as? String, let html = d["html"] as? String else { return nil }
            return Block(id: id, html: html, pending: d["pending"] as? Bool ?? false)
        }
        return BlocksResult(blocks: blocks, focus: r["focus"] as? [String] ?? [], revision: (r["revision"] as? NSNumber)?.intValue ?? 0)
    }

    struct Snapshot { var html: String; var annotations: DocumentAnnotations }
    struct ApplyResult { var html: String; var annotations: DocumentAnnotations; var missing: [String]; var changes: Int }

    func snapshot() async -> Snapshot? {
        guard let r = try? await call("return window.margins.snapshot()") as? [String: Any],
              let html = r["html"] as? String else { return nil }
        return Snapshot(html: html, annotations: Self.annotations(in: r) ?? DocumentAnnotations())
    }

    func apply(step: Int, edits: [EditOp], direct: Bool, runID: UUID, expectedRevision: Int, parentRunID: UUID? = nil) async throws -> ApplyResult {
        let payload = edits.map { ["op": $0.op.rawValue, "blockId": $0.blockId, "html": $0.html] }
        var options: [String: Any] = ["runId": runID.uuidString.lowercased(), "expectedRevision": expectedRevision]
        if let parentRunID { options["parentRunId"] = parentRunID.uuidString.lowercased() }
        let r = try await call("return window.margins.applyEdits(step, edits, direct, options)",
                               ["step": step, "edits": payload, "direct": direct,
                                "options": options]) as? [String: Any] ?? [:]
        try Self.validateRevision(r)
        return ApplyResult(html: r["html"] as? String ?? "", annotations: Self.annotations(in: r) ?? DocumentAnnotations(),
                           missing: r["missing"] as? [String] ?? [],
                           changes: (r["changes"] as? NSNumber)?.intValue ?? 0)
    }

    func setParagraphWorking(step: Int, blockID: String?) async {
        _ = try? await call("window.margins.setParagraphWorking(step, blockId)",
                            ["step": step, "blockId": blockID.map { $0 as Any } ?? NSNull()])
    }

    func resolve(accept: Bool, step: Int? = nil, all: Bool = false) async {
        var filter: [String: Any] = [:]
        if let step { filter["step"] = step }
        if all { filter["all"] = true }
        _ = try? await call("return window.margins.\(accept ? "accept" : "reject")(filter)", ["filter": filter])
    }

    struct RefineContext { var blockId: String; var step: Int; var original: String; var proposed: String; var revision: Int }

    func refineContext(cid: String) async -> RefineContext? {
        guard let r = try? await call("return window.margins.refineContext(cid)", ["cid": cid]) as? [String: Any],
              let bid = r["blockId"] as? String else { return nil }
        return RefineContext(blockId: bid, step: (r["step"] as? NSNumber)?.intValue ?? 0,
                             original: r["original"] as? String ?? "", proposed: r["proposed"] as? String ?? "",
                             revision: (r["revision"] as? NSNumber)?.intValue ?? 0)
    }

    func applyRefinement(cid: String, html: String, count: Int, runID: UUID, expectedRevision: Int, parentRunID: UUID? = nil) async throws -> Snapshot? {
        var options: [String: Any] = ["runId": runID.uuidString.lowercased(), "expectedRevision": expectedRevision]
        if let parentRunID { options["parentRunId"] = parentRunID.uuidString.lowercased() }
        guard let r = try await call("return window.margins.applyRefinement(cid, html, count, options)",
                        ["cid": cid, "html": html, "count": count,
                         "options": options]) as? [String: Any] else { return nil }
        try Self.validateRevision(r)
        guard let html = r["html"] as? String else { return nil }
        return Snapshot(html: html, annotations: Self.annotations(in: r) ?? DocumentAnnotations())
    }

    func refineFailed(cid: String) async { _ = try? await call("window.margins.refineFailed(cid)", ["cid": cid]) }
    func highlight(step: Int?) async {
        _ = try? await call("window.margins.highlightStep(step)", ["step": step.map { $0 as Any } ?? NSNull()])
    }
    func reveal(step: Int) async { _ = try? await call("window.margins.revealStep(step)", ["step": step]) }
    func preview(_ html: String, annotations: DocumentAnnotations = DocumentAnnotations()) async {
        _ = try? await call("window.margins.preview(html, annotations)", ["html": html, "annotations": Self.jsonObject(annotations)])
    }
    func endPreview() async { _ = try? await call("window.margins.endPreview()") }
    func insertImage(src: String, alt: String) async {
        _ = try? await call("window.margins.insertImage(src, alt)", ["src": src, "alt": alt])
    }
    func setOutline(_ on: Bool) async { _ = try? await call("window.margins.setOutline(on)", ["on": on]) }
    func setThreads(_ list: [[String: Any]]) async { _ = try? await call("window.margins.setThreads(list)", ["list": list]) }
    func setAnnotationRuns(_ runs: [AnnotationRun], availableIntentIDs: Set<UUID>? = nil) async {
        var payload = Self.jsonObject(runs) as? [[String: Any]] ?? []
        for index in payload.indices {
            if let availableIntentIDs { payload[index]["canRevealInstruction"] = availableIntentIDs.contains(runs[index].intentId) }
            for key in ["id", "intentId", "parentRunId"] {
                if let value = payload[index][key] as? String { payload[index][key] = value.lowercased() }
            }
        }
        _ = try? await call("window.margins.setAnnotationRuns(runs)", ["runs": payload])
    }

    static func annotations(in body: [String: Any]) -> DocumentAnnotations? {
        guard let value = body["annotations"], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(DocumentAnnotations.self, from: data)
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }

    private static func validateRevision(_ body: [String: Any]) throws {
        if (body["conflict"] as? Bool) == true || body["error"] as? String == "revision-conflict" {
            throw ProviderError.protocolError("The document changed while the agent was working. Your edits were kept; retry the instruction on the current document.")
        }
    }
    func openThread(_ id: UUID) async {
        _ = try? await call("window.margins.openThread(id)", ["id": id.uuidString.lowercased()])
    }
    func showFind() async {
        webView.window?.makeFirstResponder(webView)
        _ = try? await call("window.margins.showFind()")
    }
    func findNext(backward: Bool = false) async {
        _ = try? await call("window.margins.findNext(backward)", ["backward": backward])
    }
    func format(_ command: String) async {
        webView.window?.makeFirstResponder(webView)
        _ = try? await call("window.margins.format(command)", ["command": command])
    }
    func editLink() async { _ = try? await call("window.margins.editLink()") }

    fileprivate func addAsset(_ body: Any) -> String? {
        guard let d = body as? [String: Any], let mime = d["mime"] as? String, mime.hasPrefix("image/"),
              let b64 = d["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
        return onAddAsset?(data, mime)
    }

    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    // Keep links from navigating the editor away.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if Self.openableSchemes.contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

struct EditorView: NSViewRepresentable {
    let bridge: EditorBridge
    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Serves images stored in the document to the editor. `<img>` rendering means SVG scripts never run.
private final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var lookup: ((String) -> Asset?)?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let id = MarginsDocument.assetID(fromSrc: url.absoluteString),
              let asset = lookup?(id) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": asset.mime,
            "Content-Length": String(asset.data.count),
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
        ])!
        task.didReceive(response)
        task.didReceive(asset.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// `await webkit.messageHandlers.assets.postMessage({mime, data})` → asset URL.
private final class AssetUploadHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: EditorBridge?
    init(_ b: EditorBridge) { bridge = b }
    @MainActor
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let src = bridge?.addAsset(message.body) else { return (nil, "Unsupported image") }
        return (src, nil)
    }
}

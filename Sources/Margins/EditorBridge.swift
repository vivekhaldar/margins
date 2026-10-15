import AppKit
import SwiftUI
import WebKit
import MarginsCore

/// Owns the WKWebView that hosts the tracked-changes editor and exposes a typed async API over it.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onMessage: ((String, [String: Any]) -> Void)?
    private var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(WeakHandler(self), name: "margins")
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

    func load(_ html: String) async {
        _ = try? await call("return window.margins.load(html)", ["html": html])
    }

    func html() async -> String? {
        try? await call("return window.margins.html()") as? String
    }

    struct BlocksResult { var blocks: [Block]; var focus: [String] }

    func blocks() async throws -> BlocksResult {
        let r = try await call("return window.margins.getBlocks()") as? [String: Any] ?? [:]
        let blocks = (r["blocks"] as? [[String: Any]] ?? []).compactMap { d -> Block? in
            guard let id = d["id"] as? String, let html = d["html"] as? String else { return nil }
            return Block(id: id, html: html, pending: d["pending"] as? Bool ?? false)
        }
        return BlocksResult(blocks: blocks, focus: r["focus"] as? [String] ?? [])
    }

    struct ApplyResult { var html: String; var missing: [String]; var changes: Int }

    func apply(step: Int, edits: [EditOp], direct: Bool) async throws -> ApplyResult {
        let payload = edits.map { ["op": $0.op.rawValue, "blockId": $0.blockId, "html": $0.html] }
        let r = try await call("return window.margins.applyEdits(step, edits, direct)",
                               ["step": step, "edits": payload, "direct": direct]) as? [String: Any] ?? [:]
        return ApplyResult(html: r["html"] as? String ?? "", missing: r["missing"] as? [String] ?? [],
                           changes: (r["changes"] as? NSNumber)?.intValue ?? 0)
    }

    func resolve(accept: Bool, step: Int? = nil, all: Bool = false) async {
        var filter: [String: Any] = [:]
        if let step { filter["step"] = step }
        if all { filter["all"] = true }
        _ = try? await call("return window.margins.\(accept ? "accept" : "reject")(filter)", ["filter": filter])
    }

    struct RefineContext { var blockId: String; var step: Int; var original: String; var proposed: String }

    func refineContext(cid: String) async -> RefineContext? {
        guard let r = try? await call("return window.margins.refineContext(cid)", ["cid": cid]) as? [String: Any],
              let bid = r["blockId"] as? String else { return nil }
        return RefineContext(blockId: bid, step: (r["step"] as? NSNumber)?.intValue ?? 0,
                             original: r["original"] as? String ?? "", proposed: r["proposed"] as? String ?? "")
    }

    func applyRefinement(cid: String, html: String, count: Int) async -> String? {
        try? await call("return window.margins.applyRefinement(cid, html, count)",
                        ["cid": cid, "html": html, "count": count]) as? String
    }

    func refineFailed(cid: String) async { _ = try? await call("window.margins.refineFailed(cid)", ["cid": cid]) }
    func highlight(step: Int?) async {
        _ = try? await call("window.margins.highlightStep(step)", ["step": step.map { $0 as Any } ?? NSNull()])
    }
    func reveal(step: Int) async { _ = try? await call("window.margins.revealStep(step)", ["step": step]) }
    func preview(_ html: String) async { _ = try? await call("window.margins.preview(html)", ["html": html]) }
    func endPreview() async { _ = try? await call("window.margins.endPreview()") }

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

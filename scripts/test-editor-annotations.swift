// Exercises the actual bundled WebKit editor. Screenshots use a local deterministic fixture;
// no provider request is made. Run: swift scripts/test-editor-annotations.swift [width] [light|dark]
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)
let width = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 1100
let theme = CommandLine.arguments.dropFirst(2).first ?? "dark"
app.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 850), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Margins · Attribution verification"
window.contentView = webView
window.makeKeyAndOrderFront(nil)
var finished = false
var failure: String?
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("build/verification")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription; finished = true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(100))
                let script = try String(contentsOf: root.appendingPathComponent("scripts/editor-annotations-tests.js"), encoding: .utf8)
                let result = try await webView.callAsyncJavaScript(
                    "try { \(script) } catch (error) { return {error: error.message, stack: error.stack}; }",
                    arguments: [:], in: nil, contentWorld: .page)
                guard var result = result as? [String: Any], result["error"] == nil else {
                    print("FAIL: \(String(describing: result)); appActive=\(app.isActive), windowVisible=\(window.isVisible), windowOccluded=\(!window.occlusionState.contains(.visible))"); exit(1)
                }
                if let demo = result.removeValue(forKey: "demo") as? [String: Any],
                   let html = demo["html"] as? String, let annotations = demo["annotations"],
                   let runs = demo["runs"] as? [[String: Any]], let run = runs.first {
                    let stamp = "2026-10-17T12:00:00Z"
                    let intent: [String: Any] = ["id": run["intentId"]!, "kind": "instruction", "step": 1,
                        "text": run["instruction"]!, "createdAt": stamp, "status": "done", "summary": run["summary"]!,
                        "notes": run["notes"]!, "refinements": [], "provider": run["provider"]!, "steps": run["steps"]!]
                    let version: [String: Any] = ["id": UUID().uuidString, "number": 1, "html": html,
                        "slug": "local verification fixture", "author": "agent", "detail": "Deterministic demonstration; no AI service call.",
                        "createdAt": stamp, "annotations": annotations, "annotationRuns": runs]
                    let document: [String: Any] = ["format": 2, "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "html": html,
                        "intents": [intent], "versions": [version], "nextStep": 2, "assets": [:],
                        "annotations": annotations, "annotationRuns": runs]
                    try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted,.sortedKeys])
                        .write(to: output.appendingPathComponent("attribution-demo.margins"))
                }
                result["width"] = Int(width); result["theme"] = theme
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("annotations-test-results.json"))
                try data.write(to: output.appendingPathComponent("annotations-test-results-\(Int(width))-\(theme).json"))
                print(String(data: data, encoding: .utf8)!)
                for view in ["provenance", "comment", "mixed", "history"] {
                    _ = try await webView.callAsyncJavaScript("return await window.annotationDemo(view)", arguments: ["view": view], in: nil, contentWorld: .page)
                    let image = try await webView.takeSnapshot(configuration: nil)
                    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: output.appendingPathComponent("annotations-\(view)-\(Int(width))-\(theme).png"))
                    }
                }
                print("Annotation editor checks and screenshots passed (\(Int(width))px)")
            } catch { failure = error.localizedDescription }
            finished = true
            if let failure { print("FAIL: \(failure)"); exit(1) }
            exit(0)
        }
    }
}
let delegate = Delegate()
webView.navigationDelegate = delegate
let directory = root.appendingPathComponent("Sources/Margins/Resources/Editor")
webView.loadFileURL(directory.appendingPathComponent("editor.html"), allowingReadAccessTo: directory)
DispatchQueue.main.asyncAfter(deadline: .now() + 55) { print("FAIL: Timed out loading or testing annotation editor"); exit(1) }
app.run()

// Run with: swift scripts/test-editor-semantic-zoom.swift
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = webView
window.makeKeyAndOrderFront(nil)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let script = try String(contentsOf: root.appendingPathComponent("scripts/test-semantic-zoom.js"), encoding: .utf8)
                _ = try await webView.evaluateJavaScript(script)
                let result = try await webView.callAsyncJavaScript(
                    "return await window.runSemanticZoomEditorTests()", arguments: [:], in: nil, contentWorld: .page)
                guard result as? String == "Semantic zoom editor checks passed" else {
                    print("FAIL: Unexpected result: \(String(describing: result))")
                    exit(1)
                }
                print("Semantic zoom editor checks passed")
                exit(0)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}

let delegate = Delegate()
webView.navigationDelegate = delegate
let directory = root.appendingPathComponent("Sources/Margins/Resources/Editor")
webView.loadFileURL(directory.appendingPathComponent("editor.html"), allowingReadAccessTo: directory)
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("FAIL: Timed out loading editor"); exit(1) }
app.run()

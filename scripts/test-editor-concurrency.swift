// Run: swift scripts/test-editor-concurrency.swift [editor-directory]
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Margins · Concurrent editing verification"
window.contentView = webView
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let script = try String(contentsOf: root.appendingPathComponent("scripts/editor-concurrency-tests.js"), encoding: .utf8)
                let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                guard let result = value as? [String: Any], let passed = result["passed"] as? Int else {
                    throw NSError(domain: "Concurrency", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing test result"])
                }
                let output = root.appendingPathComponent("build/verification")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("concurrency-test-results.json"))
                print("\(passed) editor concurrency checks passed")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }
}
let delegate = Delegate()
webView.navigationDelegate = delegate
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Sources/Margins/Resources/Editor", isDirectory: true)
guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("editor.html").path) else {
    print("FAIL: No editor.html in \(directory.path)"); exit(1)
}
webView.loadFileURL(directory.appendingPathComponent("editor.html"), allowingReadAccessTo: directory)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL: Concurrency checks timed out"); exit(1) }
app.run()

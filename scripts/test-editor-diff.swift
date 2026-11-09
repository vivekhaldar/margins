// Run: swift scripts/test-editor-diff.swift [editor-directory]
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
let light = CommandLine.arguments.contains("--light")
window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
window.title = "Margins · Granular diff verification"
window.contentView = webView
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let script = try String(contentsOf: root.appendingPathComponent("scripts/editor-diff-tests.js"), encoding: .utf8)
                let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                guard let result = value as? [String: Any], let passed = result["passed"] as? Int else {
                    throw NSError(domain: "Diff", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing test result"])
                }
                // Real keyboard and menu undo exercise WebKit's target ranges and
                // undo stack, which synthetic beforeinput events cannot validate.
                _ = try await webView.callAsyncJavaScript(#"""
                    window.diffPreview = margins.snapshot();
                    margins.load('<p>It is easier to use every day.</p>');
                    margins.applyEdits(1, [{op: 'replace', blockId: margins.getBlocks().blocks[0].id,
                      html: '<p>It is cheaper to use every day.</p>'}], false);
                    const p = document.querySelector('.chg > ins p'), node = p.lastChild;
                    const start = node.textContent.indexOf('every');
                    document.querySelector('#doc').focus();
                    getSelection().setBaseAndExtent(node, start, node, start + 5);
                    """#, arguments: [:], in: nil, contentWorld: .page)
                window.makeFirstResponder(webView)
                app.activate(ignoringOtherApps: true)
                webView.undoManager?.removeAllActions()
                for character in "each" {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                        isARepeat: false, keyCode: 0)!
                    window.sendEvent(event)
                    _ = try await webView.callAsyncJavaScript("return MarginsAnnotations.getState().text", arguments: [:], in: nil, contentWorld: .page)
                }
                _ = try await webView.callAsyncJavaScript(#"""
                    if (MarginsAnnotations.getState().text !== 'It is cheaper to use each day.')
                      throw new Error('Native typing in inline diff: ' + MarginsAnnotations.getState().text);
                    """#, arguments: [:], in: nil, contentWorld: .page)
                webView.undoManager?.undo()
                _ = try await webView.callAsyncJavaScript(#"""
                    if (MarginsAnnotations.getState().text !== 'It is cheaper to use every day.')
                      throw new Error('Native menu undo in inline diff: ' + MarginsAnnotations.getState().text);
                    """#, arguments: [:], in: nil, contentWorld: .page)
                webView.undoManager?.redo()
                _ = try await webView.callAsyncJavaScript(#"""
                    if (MarginsAnnotations.getState().text !== 'It is cheaper to use each day.')
                      throw new Error('Native menu redo in inline diff: ' + MarginsAnnotations.getState().text);
                    margins.load(diffPreview.html, diffPreview.annotations);
                    document.querySelector('#doc').blur(); getSelection().removeAllRanges();
                    await new Promise(resolve => setTimeout(resolve, 150));
                    if (![...CSS.highlights.get('margins-added')].some(r => r.toString() === 'cheaper'))
                      throw new Error('Preview is missing the cheaper insertion highlight');
                    """#, arguments: [:], in: nil, contentWorld: .page)
                print("Native inline typing and menu undo/redo passed")
                let output = root.appendingPathComponent("build/verification")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("diff-test-results.json"))
                let snapshot = try await webView.takeSnapshot(configuration: nil)
                if let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: output.appendingPathComponent(light ? "diff-preview-light.png" : "diff-preview.png"))
                }
                print("\(passed) editor diff checks passed")
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
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL: Diff checks timed out"); exit(1) }
app.run()

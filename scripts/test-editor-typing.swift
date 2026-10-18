// Run with: swift scripts/test-editor-typing.swift [editor-directory]
// Exercises WebKit editing commands without resetting the caret between characters.
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Margins · Typing verification"
window.contentView = webView
window.makeKeyAndOrderFront(nil)

final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                for zoom in [1.0, 0.5, 1.5, 3.0] {
                  webView.pageZoom = zoom
                  let result = try await webView.callAsyncJavaScript(#"""
                const api = window.margins, doc = document.querySelector('#doc');
                let passes = 0;
                const assert = (value, message) => { if (!value) throw new Error(message + ': ' + doc.innerHTML); passes++; };
                const caret = (node, offset = node.childNodes.length) => {
                  doc.focus(); getSelection().setPosition(node, offset);
                };
                const type = text => {
                  for (const character of text) {
                    doc.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, inputType:'insertText', data:character}));
                    document.execCommand('insertText', false, character);
                  }
                };
                const text = () => doc.textContent.replace(/\u00a0/g, ' ');
                  api.load(''); caret(doc);
                  type('Hello world');
                  assert(doc.children.length === 1 && doc.firstElementChild.tagName === 'P' && text() === 'Hello world', 'Blank document keeps typed characters in one paragraph');
                  assert(doc.querySelector('p').contains(getSelection().anchorNode), 'Caret remains in the typed paragraph');
                  const id = api.getBlocks().blocks[0].id;
                  api.flushForSave(); type('!');
                  assert(text() === 'Hello world!' && api.getBlocks().blocks[0].id === id, 'Save and context capture preserve caret and block identity');
                  document.execCommand('insertParagraph'); type('Second line');
                  assert(doc.children.length === 2 && doc.lastElementChild.textContent === 'Second line', 'Return starts one new paragraph');
                  document.execCommand('selectAll'); document.execCommand('delete'); type('Fresh start');
                  assert(doc.children.length === 1 && text() === 'Fresh start', 'Typing works after deleting all content');
                  const snapshot = api.snapshot(); api.load(snapshot.html, snapshot.annotations);
                  caret(doc.lastElementChild); type(' again');
                  assert(doc.children.length === 1 && text() === 'Fresh start again', 'Typing continues after save and reload');
                  const state = window.MarginsAnnotations.getState();
                  assert(state.text.replace(/\u00a0/g, ' ') === text() && state.spans.length > 0 && state.spans.every(span => span.origin === 'author'), 'Typing retains author attribution');
                  api.load(''); caret(doc); type('  Leading spaces');
                  assert(doc.children.length === 1 && text() === '  Leading spaces', 'Leading spaces survive blank-document normalization');
                  api.load('<p><br></p>'); caret(doc.firstElementChild, 0); type('Empty paragraph');
                  assert(doc.children.length === 1 && text() === 'Empty paragraph', 'Typing works in an existing empty paragraph');
                  api.load(''); doc.innerHTML = '<div>Keep <em>this</em> text</div>';
                  const emText = doc.querySelector('em').firstChild;
                  getSelection().setBaseAndExtent(emText, 4, emText, 1);
                  api.getBlocks();
                  assert(doc.firstElementChild.tagName === 'P' && getSelection().anchorNode === emText && getSelection().anchorOffset === 4 && getSelection().focusOffset === 1, 'DIV conversion retains inline nodes and backward selection');
                return `${passes} editor typing checks passed`;
                """#, arguments: [:], in: nil, contentWorld: .page)
                  print("\(Int(zoom * 100))%: \(result ?? "Missing result")")
                }
                webView.pageZoom = 1
                _ = try await webView.callAsyncJavaScript("window.margins.load(''); const doc = document.querySelector('#doc'); doc.focus(); getSelection().setPosition(doc, 0)", arguments: [:], in: nil, contentWorld: .page)
                webView.undoManager?.removeAllActions()
                for character in "Native typing" {
                    let key = String(character)
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                        isARepeat: false, keyCode: character == " " ? 49 : 0)!
                    window.sendEvent(event)
                    // Wait for the WebKit process to consume each native key.
                    _ = try await webView.callAsyncJavaScript("return document.querySelector('#doc').textContent", arguments: [:], in: nil, contentWorld: .page)
                }
                _ = try await webView.callAsyncJavaScript("const doc = document.querySelector('#doc'); if (doc.children.length !== 1 || doc.textContent !== 'Native typing') throw new Error('Native keyboard typing stays in one paragraph: ' + doc.innerHTML)", arguments: [:], in: nil, contentWorld: .page)
                print("Native keyboard typing passed")
                _ = try await webView.callAsyncJavaScript("document.execCommand('undo'); if (document.querySelector('#doc').textContent.trim()) throw new Error('Undo removes initial native typing')", arguments: [:], in: nil, contentWorld: .page)
                _ = try await webView.callAsyncJavaScript("document.execCommand('redo'); document.execCommand('insertText', false, '!'); const doc = document.querySelector('#doc'); if (doc.children.length !== 1 || doc.textContent !== 'Native typing!') throw new Error('Redo restores typing and caret: ' + doc.innerHTML)", arguments: [:], in: nil, contentWorld: .page)
                print("Native typing undo/redo passed")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }
}
let delegate = Delegate()
webView.navigationDelegate = delegate
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Sources/Margins/Resources/Editor", isDirectory: true)
webView.loadFileURL(directory.appendingPathComponent("editor.html"), allowingReadAccessTo: directory)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL: Typing checks timed out"); exit(1) }
app.run()

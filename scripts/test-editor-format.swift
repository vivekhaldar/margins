// Run with: swift scripts/test-editor-format.swift
import AppKit
import WebKit

let app = NSApplication.shared
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = webView
var finished = false
var failure: String?

final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
          do {
            let result = try await webView.callAsyncJavaScript(#"""
        return await
        (() => {
          const assert = (value, message) => { if (!value) throw new Error(message); };
          const api = window.margins, doc = document.querySelector('#doc');
          const messages = () => (window.__marginsLog || []).filter(m => m.type === 'submitParagraph');
          const caret = element => {
            doc.focus();
            const range = document.createRange(); range.selectNodeContents(element); range.collapse(false);
            const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
          };
          const key = options => doc.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', metaKey: true, bubbles: true, cancelable: true, ...options}));
          const select = element => {
            doc.focus(); const range = document.createRange(); range.selectNodeContents(element);
            const s = getSelection(); s.removeAllRanges(); s.addRange(range);
          };
          api.load('<p>Hello world</p>'); select(doc.querySelector('p')); api.format('bold');
          assert(doc.querySelector('b,strong')?.textContent === 'Hello world', 'Bold applies to selection');
          api.format('italic');
          assert(doc.querySelector('i,em')?.textContent === 'Hello world', 'Italic applies to selection');
          api.format('removeFormat');
          assert(!doc.querySelector('b,strong,i,em'), 'Clear formatting');
          api.load('<p>First</p><p>Second</p>'); select(doc); api.format('bullets');
          assert(doc.querySelectorAll('ul > li').length === 2, 'Bullets cover selected paragraphs');
          api.load('<p>First</p>'); caret(doc.querySelector('p')); api.format('numbers');
          assert(doc.querySelector('ol > li'), 'Numbered list');
          api.load('<p>First</p>'); caret(doc.querySelector('p')); api.format('checklist');
          assert(doc.querySelector('ul[data-task] > li > input[type=checkbox]'), 'Checklist created');
          api.format('toggleCheck');
          assert(doc.querySelector('input').checked, 'Keyboard action checks task');
          const html = api.html(); api.load(html);
          assert(doc.querySelector('input').checked, 'Checked state survives reload');
          assert(api.getBlocks().blocks[0].html.includes('checked'), 'Checked state survives agent context');
          const input = doc.querySelector('input'); input.click();
          assert(!input.checked && !api.html().includes(' checked'), 'Click unchecks and saves task');
          caret(doc.querySelector('li')); api.format('checklist');
          assert(!doc.querySelector('input') && !doc.querySelector('ul[data-task]'), 'Checklist toggles to bullets');
          api.load('<ul data-task><li><input type="checkbox" checked>First</li></ul>');
          caret(doc.querySelector('li')); document.execCommand('insertParagraph');
          doc.dispatchEvent(new InputEvent('input', {inputType:'insertParagraph', bubbles:true}));
          assert(doc.querySelectorAll('ul[data-task] > li').length === 2, 'Enter continues checklist');
          assert(!doc.querySelectorAll('input')[1].checked, 'New task is unchecked');
          api.preview('<p>Read only</p>'); select(doc.querySelector('p')); api.format('bold');
          assert(!doc.querySelector('b,strong'), 'History cannot be formatted');
          api.endPreview();
          api.load('<p>Shortcuts</p>'); select(doc.querySelector('p'));
          doc.dispatchEvent(new KeyboardEvent('keydown', {key:'b',metaKey:true,bubbles:true,cancelable:true}));
          assert(doc.querySelector('b,strong'), 'Command-B shortcut');
          const id = api.getBlocks().blocks[0].id;
          api.applyEdits(8, [{op:'replace', blockId:id, html:'<p>Proposed</p>'}], false);
          select(doc.querySelector('ins p')); api.format('italic');
          select(doc.querySelector('del p')); const before = api.html(); api.format('underline');
          assert(api.html() === before, 'Selecting a deletion does not format a previous selection');
          api.flushForSave();
          assert((window.__marginsLog || []).some(m => m.type === 'edited'), 'Formatting produces save events');
          return 'Editor formatting checks passed';
        })()
        """#, arguments: [:], in: nil, contentWorld: .page)
            if result as? String != "Editor formatting checks passed" { failure = "Unexpected result: \(String(describing: result))" }
          } catch { failure = error.localizedDescription }
          finished = true
        }

    }
}
let delegate = Delegate()
webView.navigationDelegate = delegate
let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Margins/Resources/Editor")
webView.loadFileURL(directory.appendingPathComponent("editor.html"), allowingReadAccessTo: directory)
let deadline = Date().addingTimeInterval(20)
while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
if !finished { failure = "Timed out loading editor" }
if let failure { print("FAIL: \(failure)"); exit(1) }
print("Editor formatting checks passed")

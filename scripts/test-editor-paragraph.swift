// Run with: swift scripts/test-editor-paragraph.swift
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
          api.load('<h1>Context</h1><p>Explain <em>why</em> this matters?</p>');
          const original = api.html();
          const blockId = api.getBlocks().blocks[1].id;
          caret(doc.querySelector('em')); key();
          let message = messages().at(-1);
          assert(message.text === 'Explain why this matters?', 'Entire paragraph is sent from nested inline text');
          assert(message.blockId === blockId, 'Originating block ID is sent');
          assert(api.html() === original, 'Prompt is retained until a suggestion arrives');
          const promptBlock = doc.querySelectorAll('#doc > p')[0];
          api.setParagraphWorking(1, blockId);
          assert(promptBlock.classList.contains('paragraph-working'), 'Running paragraph gets a visible marker');
          const workingStyle = getComputedStyle(promptBlock);
          assert(workingStyle.backgroundImage.includes('linear-gradient'), 'Running paragraph has a gradient background');
          assert(workingStyle.animationName === 'sh' && workingStyle.animationDuration === '1s', 'Running paragraph uses the refinement shimmer');
          assert(api.html() === original, 'Working marker is excluded from saved HTML');
          assert(!api.getBlocks().blocks[1].html.includes('paragraph-working'), 'Working marker is excluded from agent context');
          api.setParagraphWorking(2, blockId);
          api.setParagraphWorking(1, null);
          assert(promptBlock.classList.contains('paragraph-working'), 'One completed run does not clear another on the same block');
          api.setParagraphWorking(2, null);
          assert(!promptBlock.classList.contains('paragraph-working'), 'Ending the final run clears the marker without editing text');
          api.setParagraphWorking(1, blockId);
          const count = messages().length;
          key({repeat: true}); key({shiftKey: true}); key({isComposing: true});
          assert(messages().length === count, 'Repeat, composition and Shift-Enter do not submit');
          api.applyEdits(1, [{op: 'replace', blockId, html: '<p>A synthesized answer.</p>'}], false);
          assert(doc.querySelector('.chg ins').textContent.includes('A synthesized answer.'), 'Answer appears as tracked replacement');
          api.setParagraphWorking(1, null);
          assert(!doc.querySelector('.paragraph-working'), 'Completion clears marker from tracked replacement');
          api.reject({all: true});
          assert(doc.textContent.includes('Explain why this matters?'), 'Reject restores the rough prompt');
          api.load('<ul><li>Keep this item.</li><li><p>Explain this item.</p></li></ul>');
          const listId = api.getBlocks().blocks[0].id;
          caret(doc.querySelector('li p')); key();
          message = messages().at(-1);
          assert(message.blockId === listId && message.text === 'Explain this item.', 'Nested paragraph targets containing top-level block');
          api.load('<p><br></p>'); caret(doc.querySelector('p'));
          const beforeEmpty = messages().length; key();
          assert(messages().length === beforeEmpty, 'Empty paragraph is ignored');
          api.preview('<p>Historical prompt</p>'); caret(doc.querySelector('p')); key();
          assert(messages().length === beforeEmpty, 'History preview cannot submit');
          api.endPreview(); api.load('<p>Before</p>');
          doc.querySelector('p').textContent = 'Typed just before quitting';
          doc.dispatchEvent(new Event('input', {bubbles: true}));
          api.flushForSave();
          const edits = () => (window.__marginsLog || []).filter(m => m.type === 'edited');
          assert(edits().at(-1).html.includes('Typed just before quitting'), 'Quit flush delivers typing before its debounce timer');
          const editCount = edits().length; api.flushForSave();
          assert(edits().length === editCount, 'Repeated save flush does not duplicate edit events');
          const quitId = api.getBlocks().blocks[0].id;
          api.applyEdits(7, [{op: 'replace', blockId: quitId, html: '<p>Reviewed before quitting</p>'}], false);
          api.accept({all: true}); api.flushForSave();
          const review = (window.__marginsLog || []).filter(m => m.type === 'reviewed').at(-1);
          assert(review.accepted === 1 && review.html.includes('Reviewed before quitting'), 'Quit flush delivers pending review events');
          return 'Editor paragraph checks passed';
        })()
        """#, arguments: [:], in: nil, contentWorld: .page)
            if result as? String != "Editor paragraph checks passed" { failure = "Unexpected result: \(String(describing: result))" }
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
print("Editor paragraph checks passed")

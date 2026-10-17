// Run with: swift scripts/test-editor-find.swift
import AppKit
import WebKit

let app = NSApplication.shared
let width = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 1000
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
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
          const api = window.margins, input = document.querySelector('#findin');
          const count = () => document.querySelector('#findcount').textContent;
          const query = value => { input.value = value; input.dispatchEvent(new Event('input')); };
          const key = (value, shift = false) => input.dispatchEvent(new KeyboardEvent('keydown', {key: value, shiftKey: shift, bubbles: true}));
          const outline = document.querySelector('#outline');
          const alignedOutline = () => assert(Math.abs(outline.getBoundingClientRect().top - document.querySelector('#scroll').getBoundingClientRect().top) < 1, 'Outline starts below all header rows');
          api.load('<h1>Title</h1><h2>Section</h2><p>Alpha <strong>be</strong>ta ALPHA a.b</p><p>beta</p>');
          api.setOutline(true);
          alignedOutline();
          const original = api.html();
          api.showFind();
          alignedOutline();
          assert(outline.getBoundingClientRect().top >= document.querySelector('#findbar').getBoundingClientRect().bottom, 'Search does not overlap outline');
          assert(document.activeElement === input, 'Find field receives focus');
          query('alpha');
          assert(count() === '1 of 2', 'Case-insensitive count');
          assert(document.querySelectorAll('.findmark').length >= 2, 'All matches highlighted');
          key('Enter'); assert(count() === '2 of 2', 'Enter advances');
          key('Enter'); assert(count() === '1 of 2', 'Next wraps');
          key('Enter', true); assert(count() === '2 of 2', 'Previous wraps');
          query('beta'); assert(count() === '1 of 2', 'Matches across inline formatting');
          query('a.b'); assert(count() === '1 of 1', 'Query is literal');
          query('[.*'); assert(count() === 'No matches', 'Regex punctuation is escaped');
          query('absent'); assert(count() === 'No matches', 'No results');
          query(''); assert(count() === '', 'Empty query');
          query('alpha');
          assert(api.html() === original, 'Search does not change saved HTML');
          key('Escape');
          alignedOutline();
          assert(document.querySelector('#findbar').hidden, 'Escape closes search');
          assert(!document.querySelector('.findmark'), 'Close clears highlights');
          api.preview('<p>Historical alpha</p>'); api.showFind(); query('alpha');
          assert(count() === '1 of 1', 'Search works in historical preview');
          assert(document.querySelector('#doc').contentEditable === 'false', 'Preview stays read-only');
          api.endPreview(); query('alpha'); assert(count() === '1 of 2', 'Search refreshes after preview');
          document.querySelector('#doc p').firstChild.textContent = 'Changed ';
          return new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
            try {
              assert(count() === '1 of 1', 'Search refreshes after editing');
              resolve('Editor find checks passed');
            } catch (error) { resolve('FAIL: ' + error.message); }
          })));
        })()
        """#, arguments: [:], in: nil, contentWorld: .page)
            if result as? String != "Editor find checks passed" { failure = "Unexpected result: \(String(describing: result))" }
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
print("Editor find checks passed")

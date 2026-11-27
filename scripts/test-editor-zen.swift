// Run with: swift scripts/test-editor-zen.swift
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)
let width = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 1000
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = webView
window.makeKeyAndOrderFront(nil)
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
          const api = window.margins, zen = window.MarginsZen, doc = document.querySelector('#doc');
          const frame = () => new Promise(resolve => setTimeout(resolve, 350));
          const exits = () => (window.__marginsLog || []).filter(m => m.type === 'zenExit').length;
          const escape = target => target.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true}));
          api.load('<h1>Title here</h1><p>One two three</p><p>Four five</p>');
          const original = api.html();
          const originalSnapshot = JSON.stringify(api.snapshot());
          api.setZenMode({enabled: true, typewriter: true, paragraphFocus: true});
          assert(document.body.classList.contains('zen') && document.body.classList.contains('zen-focus'), 'Zen classes on body');
          assert(getComputedStyle(document.querySelector('#bar')).display === 'none', 'Editor bar hidden in Zen');
          const second = doc.querySelectorAll('p')[1];
          doc.focus();
          getSelection().collapse(second.firstChild, 2);
          return frame().then(() => {
            try {
              assert(getComputedStyle(second).opacity === '1', 'Active paragraph stays bright');
              assert(Number(getComputedStyle(doc.querySelector('h1')).opacity) < 1, 'Other blocks dim');
              assert(api.html() === original, 'Paragraph focus never enters saved HTML');
              assert(JSON.stringify(api.snapshot()) === originalSnapshot, 'Paragraph focus never enters snapshots');
              assert(!/zen/.test(doc.outerHTML), 'No Zen classes or attributes on document content');
              assert(zen.wordCount() === 7, 'Word count matches prose: ' + zen.wordCount());
              const chg = document.createElement('div');
              chg.className = 'chg';
              chg.innerHTML = '<del>gone words</del><ins>kept</ins>';
              doc.appendChild(chg);
              assert(zen.wordCount() === 8, 'Deleted diff text is not counted: ' + zen.wordCount());
              chg.remove();
              api.showFind();
              escape(document.querySelector('#findin'));
              assert(exits() === 0, 'Escape closes find without exiting Zen');
              assert(document.querySelector('#findbar').hidden, 'Find bar closed');
              doc.focus();
              escape(doc);
              assert(exits() === 0, 'Escape while editing does not exit Zen');
              doc.blur();
              escape(document.body);
              assert(exits() === 1, 'Bare Escape exits Zen');
              api.setZenMode({enabled: false});
              assert(!document.body.classList.contains('zen'), 'Zen off');
              assert(getComputedStyle(document.querySelector('#bar')).display !== 'none', 'Editor bar restored');
              return 'Editor zen checks passed';
            } catch (error) { return 'FAIL: ' + error.message; }
          });
        })()
        """#, arguments: [:], in: nil, contentWorld: .page)
            if result as? String != "Editor zen checks passed" { failure = "Unexpected result: \(String(describing: result))" }
          } catch { failure = error.localizedDescription }
          finished = true
          if let failure { print("FAIL: \(failure)"); exit(1) }
          print("Editor zen checks passed"); exit(0)
        }

    }
}
let delegate = Delegate()
webView.navigationDelegate = delegate
let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Margins/Resources/Editor")
webView.loadFileURL(directory.appendingPathComponent("editor.html"), allowingReadAccessTo: directory)
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("FAIL: Timed out loading editor"); exit(1) }
app.run()

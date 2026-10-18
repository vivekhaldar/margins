// After `swift build --product Margins`, compile and run:
// swiftc -parse-as-library -I .build/out/Products/Debug \
//   Sources/Margins/{AppState,EditorBridge,DocumentWindows,ContentView,IntentPane,HistoryView,LocalState,InterfaceZoom}.swift \
//   scripts/test-app-zoom.swift .build/out/Products/Debug/MarginsCore.o \
//   -o .build/out/Products/Debug/MarginsZoomChecks
// .build/out/Products/Debug/MarginsZoomChecks
// Uses isolated preferences and build/verification/zoom; makes no provider calls.
import AppKit
import MarginsCore
import SwiftUI

@main struct ZoomChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await run(); print("Native app zoom checks passed"); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { print("FAIL: Native app zoom test timed out"); exit(1) }
        app.run()
    }

    @MainActor private static func run() async throws {
        let suite = "MarginsZoomChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/verification/zoom")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.margins")
        var intent = Intent(step: 1, text: "Make this clearer", provider: "Local fixture")
        intent.status = .done
        intent.summary = "A completed instruction for zoom verification."
        var doc = MarginsDocument(intents: [intent])
        doc.snapshot(html: "<h1>Zoom verification</h1><h2>Section one</h2><p>Text stays editable while the whole interface zooms.</p>", slug: "Zoom fixture", author: .you)
        try doc.encoded().write(to: url)
        let state = AppState(untitledURL: url, defaults: defaults)
        state.providers = []
        state.open(url)
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(state))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await state.editor.ready()
        state.showHistory = true
        try await Task.sleep(for: .milliseconds(400))
        guard let window = state.editor.webView.window, let content = window.contentView else {
            throw failure("Editor is in the native window")
        }
        window.makeKeyAndOrderFront(nil)
        var passes = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw failure(message) }
            passes += 1; print("✓ \(message)")
        }
        let original = await state.editor.html()
        guard let composer = views(content).compactMap({ $0 as? NSTextView }).first else {
            throw failure("Instruction composer is present")
        }
        window.makeFirstResponder(composer)
        composer.insertText("An unsent instruction", replacementRange: NSRange(location: 0, length: 0))
        let selection = composer.selectedRange()
        for target in [1.0, 1.5, 0.5, 3.0, 1.0] {
            state.resetZoom()
            while state.zoom < target { state.zoomIn() }
            while state.zoom > target { state.zoomOut() }
            try await Task.sleep(for: .milliseconds(300))
            content.layoutSubtreeIfNeeded()
            let physical = composer.convert(composer.bounds, to: nil)
            try check(abs(physical.width / composer.bounds.width - target) < 0.01 &&
                      abs(physical.height / composer.bounds.height - target) < 0.01,
                      "Instruction composer scales at \(Int(target * 100))%")
            try check(state.editor.webView.pageZoom == target, "Editor uses the same zoom factor")
            try check(window.firstResponder === composer && composer.string == "An unsent instruction" &&
                      composer.selectedRange() == selection, "Zoom retains composer focus, text, and caret")
            let point = content.superview!.convert(NSPoint(x: physical.midX, y: physical.midY), from: nil)
            let hit = content.hitTest(point)
            try check(hit === composer || hit?.isDescendant(of: composer) == true,
                      "Composer hit testing follows zoomed coordinates")
            let layout = try await state.editor.call("return {width:innerWidth, outlineTop:document.querySelector('#outline').getBoundingClientRect().top, scrollTop:document.querySelector('#scroll').getBoundingClientRect().top}") as! [String: Any]
            let cssWidth = layout["width"] as! Double
            try check(abs(state.editor.webView.bounds.width / cssWidth - target) < 0.02,
                      "WebKit viewport scales once, without a second native transform")
            try check(abs((layout["outlineTop"] as! Double) - (layout["scrollTop"] as! Double)) < 1,
                      "Outline stays below the editor controls")
            let frame = content.superview ?? content
            if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let url = state.fileURL.deletingLastPathComponent().appendingPathComponent("app-\(Int(target * 100)).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        composer.insertText(" after zoom", replacementRange: composer.selectedRange())
        try check(composer.string == "An unsent instruction after zoom", "Typing continues after zooming")
        let current = await state.editor.html()
        try check(current == original && !state.busy, "Zoom does not change document text or run the agent")
        for _ in 0..<20 { state.zoomIn() }
        try check(state.zoom == 3, "Zoom in stops at 300%")
        for _ in 0..<20 { state.zoomOut() }
        try check(state.zoom == 0.5, "Zoom out stops at 50%")
        state.resetZoom(); state.zoomIn(); state.zoomIn()
        let reopened = AppState(untitledURL: state.fileURL, defaults: UserDefaults(suiteName: suite)!)
        try check(reopened.zoom == 1.25 && reopened.editor.webView.pageZoom == 1.25,
                  "New windows inherit the saved zoom")
        state.resetZoom()
        try check(state.zoom == 1 && state.editor.webView.pageZoom == 1, "Actual Size resets native and web zoom")
        print("\(passes) native app zoom checks passed")
    }

    @MainActor private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views($0) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MarginsZoomChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

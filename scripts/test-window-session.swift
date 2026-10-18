// Native lifecycle checks using the real DocumentWindows coordinator and in-memory preferences.
// After `swift build --product Margins`, compile with:
// swiftc -parse-as-library -I .build/out/Products/Debug Sources/Margins/DocumentWindows.swift \
//   scripts/test-window-session.swift .build/out/Products/Debug/MarginsCore.o -o .build/test-window-session
// Run .build/test-window-session. No user preferences or documents are changed.
import AppKit
import MarginsCore
import SwiftUI

final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func url(forKey key: String) -> URL? { values[key] as? URL }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

// Document loading and editor behavior are covered separately. Keep this harness isolated
// from AppState's real autosave folder, provider processes, and application preferences.
@MainActor final class AppState: ObservableObject {
    @Published var fileURL: URL
    let editor = TestEditor()
    var saved = false
    var stopped = false
    static var documentsFolder: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/window-session-fixtures") }
    static func newUntitledURL() -> URL { documentsFolder.appendingPathComponent("Untitled.margins") }
    init(untitledURL: URL? = nil) { fileURL = untitledURL ?? Self.newUntitledURL() }
    func open(_ url: URL) { fileURL = url }
    func saveNow(includeEmpty: Bool = false) { saved = true }
    func flushAndSave(includeEmpty: Bool = false) async { await editor.flushForSave(); saveNow(includeEmpty: includeEmpty) }
    func stopAll() { stopped = true }
    func shutdownProviders() {}
}
@MainActor final class TestEditor {
    var flushed = false
    func flushForSave() async { flushed = true }
}
struct ContentView: View { var body: some View { Text("Test document") } }

@main struct WindowSessionChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let dir = AppState.documentsFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("First.margins")
        let second = dir.appendingPathComponent("Second.margins")
        for url in [first, second] { try MarginsDocument().encoded().write(to: url) }
        let defaults = MemoryDefaults()
        let original = WindowSession(windows: [
            .init(url: first, frame: "{{20, 40}, {1000, 700}}"),
            .init(url: second, frame: "{{60, 80}, {1100, 750}}")
        ], activeURL: second)
        defaults.set(try JSONEncoder().encode(original), forKey: "openDocumentWindows")
        let manager = DocumentWindows(defaults: defaults)
        let firstState = manager.makeState(url: nil)
        precondition(firstState.fileURL == first, "initial scene uses first saved document")
        let window1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let window2 = NSWindow(contentRect: window1.frame, styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        manager.register(window1, state: firstState)
        var routed: [URL] = []
        manager.openWindow = { routed.append($0) }
        precondition(routed == [second], "other saved windows are queued exactly once")
        let secondState = manager.makeState(url: second)
        manager.register(window2, state: secondState)
        // Drain the deferred window-geometry callbacks.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        precondition(!window1.isRestorable && !window2.isRestorable, "system restoration cannot duplicate managed windows")
        precondition(firstState.saved && secondState.saved, "blank windows have durable documents")
        func savedSession() throws -> WindowSession {
            try JSONDecoder().decode(WindowSession.self, from: defaults.data(forKey: "openDocumentWindows")!)
        }
        let both = try savedSession()
        precondition(both.windows.count == 2, "both windows recorded")
        let renamed = dir.appendingPathComponent("Renamed.margins")
        secondState.fileURL = renamed
        manager.persistSession()
        let afterRename = try savedSession()
        precondition(afterRename.windows.contains { $0.url == renamed }, "Save As updates the session URL")
        secondState.fileURL = second
        manager.close(window1)
        let afterClose = try savedSession()
        precondition(afterClose.windows.map(\.url) == [second], "explicitly closed windows stay closed")
        await manager.prepareToQuit()
        precondition(secondState.editor.flushed && secondState.stopped, "quit drains pending edits and stops agents")
        let beforeClose = defaults.data(forKey: "openDocumentWindows")
        manager.close(window2)
        precondition(defaults.data(forKey: "openDocumentWindows") == beforeClose, "quit-time close notifications preserve the session")
        let restarted = DocumentWindows(defaults: defaults)
        precondition(restarted.makeState(url: nil).fileURL == second, "restart reopens surviving document")
        let emptyDefaults = MemoryDefaults()
        emptyDefaults.set(try JSONEncoder().encode(WindowSession()), forKey: "openDocumentWindows")
        emptyDefaults.values["lastDocument"] = first
        precondition(DocumentWindows(defaults: emptyDefaults).makeState(url: nil).fileURL != first, "an empty session overrides the legacy last-document preference")
        let legacy = MemoryDefaults()
        legacy.values["lastDocument"] = first
        precondition(DocumentWindows(defaults: legacy).makeState(url: nil).fileURL == first, "legacy last document migrates")
        print("Window session lifecycle checks passed")
    }
}

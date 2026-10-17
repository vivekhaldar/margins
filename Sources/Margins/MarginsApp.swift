import AppKit
import MarginsCore
import SwiftUI

@main
struct MarginsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @FocusedObject private var focusedState: AppState?
    @Environment(\.openWindow) private var openWindow

    private var state: AppState { focusedState ?? DocumentWindows.shared.settingsState }

    var body: some Scene {
        WindowGroup("Margins", id: "document", for: URL.self) { $url in
            DocumentWindow(url: $url)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") { openWindow(id: "document") }.keyboardShortcut("n")
                Button("New Window") { openWindow(id: "document") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open…") { DocumentWindows.shared.showOpenPanel() }.keyboardShortcut("o")
                Divider()
                // Keep Close explicit alongside the custom File commands.
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save As…") { state.showSavePanel() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export HTML…") { state.exportHTML() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Show in Finder") { state.revealInFinder() }
                Button("Show Markdown in Finder") { state.revealMarkdown() }
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Document…") { Task { await state.editor.showFind() } }
                    .keyboardShortcut("f")
                Button("Find Next") { Task { await state.editor.findNext() } }
                    .keyboardShortcut("g")
                Button("Find Previous") { Task { await state.editor.findNext(backward: true) } }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu("Format") {
                Button("Bold") { Task { await state.editor.format("bold") } }.keyboardShortcut("b")
                Button("Italic") { Task { await state.editor.format("italic") } }.keyboardShortcut("i")
                Button("Underline") { Task { await state.editor.format("underline") } }.keyboardShortcut("u")
                Divider()
                Button("Bulleted List") { Task { await state.editor.format("bullets") } }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Button("Numbered List") { Task { await state.editor.format("numbers") } }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                Button("Checklist") { Task { await state.editor.format("checklist") } }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                Button("Toggle Checked") { Task { await state.editor.format("toggleCheck") } }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Clear Inline Formatting") { Task { await state.editor.format("removeFormat") } }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandMenu("Insert") {
                Button("Link…") { state.editLink() }.keyboardShortcut("k")
                Button("Image…") { state.insertImageFromFile() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom In") { state.zoomIn() }.keyboardShortcut("+")
                Button("Zoom Out") { state.zoomOut() }.keyboardShortcut("-")
                Button("Actual Size") { state.resetZoom() }.keyboardShortcut("0")
                Divider()
                Button(state.showOutline ? "Hide Outline" : "Show Outline") { state.showOutline.toggle() }
                    .keyboardShortcut("o", modifiers: [.command, .control])
                Divider()
            }
            CommandMenu("Review") {
                Button("Accept All Changes") { state.reviewAll(accept: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Reject All Changes") { state.reviewAll(accept: false) }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
                Button(state.showHistory ? "Hide History" : "Show History") { state.showHistory.toggle() }
            }
            CommandMenu("Agent") {
                Picker("Tools", selection: Binding(get: { state.toolPolicy }, set: { state.toolPolicy = $0 })) {
                    ForEach(AgentToolPolicy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Stop All") { state.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!state.busy)
                Divider()
                Button("Project Folder…") { state.chooseProjectFolder() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Stop Using Project Folder") { state.setProjectFolder(nil) }
                    .disabled(state.doc.projectFolder == nil)
                Button(state.projectURL == nil ? "Reveal Agent Workspace" : "Show Project in Finder") { state.revealWorkspace() }
            }
        }

        Settings {
            SettingsView().environmentObject(DocumentWindows.shared.settingsState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no Info.plist).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installZoomKeys()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowSessionChanged(_:)),
                                                   name: name, object: nil)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated { DocumentWindows.shared.close(window) }
    }

    @objc private func windowSessionChanged(_ notification: Notification) {
        MainActor.assumeIsolated { DocumentWindows.shared.persistSession() }
    }

    private var awaitingTermination = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !awaitingTermination {
            awaitingTermination = true
            Task { @MainActor in
                await DocumentWindows.shared.prepareToQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// ⌘= / ⌘+ / ⌘- / ⌘0 regardless of Shift or keyboard layout quirks (menu matching alone misses unshifted ⌘=).
    private var zoomMonitor: Any?
    private func installZoomKeys() {
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods == .command, let ch = event.charactersIgnoringModifiers else { return event }
            guard let state = MainActor.assumeIsolated({ DocumentWindows.shared.keyState }) else { return event }
            switch ch {
            case "=", "+": MainActor.assumeIsolated { state.zoomIn() }
            case "-", "_": MainActor.assumeIsolated { state.zoomOut() }
            case "0": MainActor.assumeIsolated { state.resetZoom() }
            default: return event
            }
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { DocumentWindows.shared.open(url) }
        }
    }

    // The explicit document session also works when macOS's Resume setting is disabled.
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            DocumentWindows.shared.shutdown()
        }
    }
}

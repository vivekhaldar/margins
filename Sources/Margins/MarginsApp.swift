import AppKit
import MarginsCore
import SwiftUI

@main
struct MarginsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Margins", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") { state.newDocument() }.keyboardShortcut("n")
                Button("Open…") { state.showOpenPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save As…") { state.showSavePanel() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export HTML…") { state.exportHTML() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Show in Finder") { state.revealInFinder() }
                Button("Show Markdown in Finder") { state.revealMarkdown() }
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
                Picker("Tools", selection: $state.toolPolicy) {
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
            SettingsView().environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no Info.plist).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installZoomKeys()
    }

    /// ⌘= / ⌘+ / ⌘- / ⌘0 regardless of Shift or keyboard layout quirks (menu matching alone misses unshifted ⌘=).
    private var zoomMonitor: Any?
    private func installZoomKeys() {
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods == .command, let ch = event.charactersIgnoringModifiers else { return event }
            let state = MainActor.assumeIsolated { AppState.shared }
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
        if let url = urls.first { Task { @MainActor in AppState.shared.open(url) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.saveNow()
            AppState.shared.shutdownProviders()
        }
    }
}

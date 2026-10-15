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
            }
            CommandMenu("Review") {
                Button("Accept All Changes") { state.reviewAll(accept: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Reject All Changes") { state.reviewAll(accept: false) }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
                Button(state.showHistory ? "Hide History" : "Show History") { state.showHistory.toggle() }
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

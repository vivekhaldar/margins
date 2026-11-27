import Foundation
import MarginsCore

extension AppState {
    // MARK: - Zen Mode (#6)

    func toggleZenMode() { zenMode.toggle() }

    func loadZenPreferences() {
        let typewriter = defaults.bool(forKey: "zenTypewriterMode")
        let focus = defaults.bool(forKey: "zenParagraphFocus")
        if typewriter != zenTypewriter { zenTypewriter = typewriter }
        if focus != zenParagraphFocus { zenParagraphFocus = focus }
    }

    func persistZenPreferences(changed: Bool) {
        guard changed else { return }
        defaults.set(zenTypewriter, forKey: "zenTypewriterMode")
        defaults.set(zenParagraphFocus, forKey: "zenParagraphFocus")
        pushZenMode()
    }

    /// Entering hides the instruction pane, history inspector, and toolbar (see ContentView); exiting restores them.
    func zenModeChanged() {
        if zenMode {
            zenRestoreHistory = showHistory
            showHistory = false
        } else if zenRestoreHistory {
            showHistory = true
            zenRestoreHistory = false
        }
        pushZenMode()
    }

    func pushZenMode() {
        let (on, typewriter, focus) = (zenMode, zenTypewriter, zenParagraphFocus)
        Task { await editor.setZenMode(enabled: on, typewriter: typewriter, paragraphFocus: focus) }
    }

    /// Handles Zen messages from the editor pill and Escape key. Returns false for other message types.
    func handleZenMessage(_ type: String, _ body: [String: Any]) -> Bool {
        switch type {
        case "zenExit":
            zenMode = false
        case "zenPrefs":
            if let typewriter = body["typewriter"] as? Bool { zenTypewriter = typewriter }
            if let focus = body["paragraphFocus"] as? Bool { zenParagraphFocus = focus }
        default:
            return false
        }
        return true
    }
}

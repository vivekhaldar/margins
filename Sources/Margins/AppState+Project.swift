import AppKit
import Foundation
import MarginsCore

extension AppState {
    // MARK: - Project Folder

    var workspaceURL: URL { projectURL ?? AgentContext.workspace(for: doc.id) }

    func revealWorkspace() { NSWorkspace.shared.activateFileViewerSelecting([workspaceURL]) }

    /// Per-machine project folder path, falling back to legacy `doc.projectFolder` for migration.
    var projectFolderPath: String? {
        _ = projectFolderRevision
        return projectFolderStore.folder(for: doc.id, fallbackDocumentFolder: doc.projectFolder)
    }

    /// The document's project folder, if set and still present.
    var projectURL: URL? {
        guard let p = projectFolderPath else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    var projectName: String? { projectFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent } }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Project"
        panel.message = "The agent will work in this folder: it can read it and, with Full agent tools, change files and run commands there."
        if let p = projectFolderPath { panel.directoryURL = URL(fileURLWithPath: p) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProjectFolder(url)
        if !toolPolicy.canWrite { offerFullAgent(for: url) }
    }

    func setProjectFolder(_ url: URL?) {
        projectFolderStore.setFolder(url?.standardizedFileURL.path, for: doc.id)
        projectFolderRevision += 1
        if doc.projectFolder != nil {
            doc.projectFolder = nil
            scheduleSave()
        }
    }

    /// Changing files needs Full agent: Codex and Claude can't ask mid-run, so Research is read-only for them.
    private func offerFullAgent(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Let the agent change files in “\(url.lastPathComponent)”?"
        alert.informativeText = """
            Agent tools are set to \(toolPolicy.shortTitle). To write code, edit files and run builds or tests in this \
            project, switch to Full agent. With Research, Copilot asks before each change; Codex and Claude can only read.
            """
        alert.addButton(withTitle: "Use Full Agent")
        alert.addButton(withTitle: "Keep \(toolPolicy.shortTitle)")
        if alert.runModal() == .alertFirstButtonReturn { toolPolicy = .full }
    }

    func openProjectInTerminal() {
        guard let url = projectURL else { return }
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }

    func openProjectFile(_ path: String) {
        guard let root = projectURL else { return }
        let url = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
    }

    /// Snapshot of the project's working tree before an agent run (nil if no project, no tools, or not git).
    func projectSnapshot(_ agent: AgentContext?) async -> (URL, ProjectChanges.Snapshot)? {
        guard let agent, agent.project else { return nil }
        let dir = agent.workspace
        return await Task.detached { ProjectChanges.snapshot(dir).map { (dir, $0) } }.value
    }

    /// Records which project files the run touched on the intent.
    func recordProjectChanges(_ before: (URL, ProjectChanges.Snapshot)?, step: Int, session: UUID) async {
        guard documentSessionID == session else { return }
        guard let (dir, snap) = before else { return }
        let files = await Task.detached { ProjectChanges.snapshot(dir).map { ProjectChanges.changed(from: snap, to: $0) } }.value ?? []
        guard documentSessionID == session else { return }
        if let runID = activeRunIDs[step], let index = doc.annotationRuns.firstIndex(where: { $0.id == runID }) {
            // Invocation evidence is independent of earlier invocations of this intent.
            doc.annotationRuns[index].files = files
        }
        if !files.isEmpty { updateIntent(step) { $0.files = Array(Set(($0.files ?? []) + files)).sorted() } }
    }
}

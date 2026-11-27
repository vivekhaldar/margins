import AppKit
import Foundation
import MarginsCore

/// App-wide theme catalog: bundled themes plus user JSON themes from
/// `~/Library/Application Support/Margins/Themes`, reloaded live when that folder changes.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var themes: [MarginsTheme] = [.builtInDefault]
    private var source: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    static var userThemesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Margins/Themes", isDirectory: true)
    }

    static var bundledThemesDirectory: URL? {
        EditorBridge.editorDirectory?.deletingLastPathComponent().appendingPathComponent("Themes", isDirectory: true)
    }

    private init() {
        reload()
        watchUserDirectory()
    }

    func theme(id: String) -> MarginsTheme { ThemeCatalog.theme(id: id, in: themes) }

    func reload() {
        let builtIn = Self.bundledThemesDirectory.map { ThemeLoader.loadDirectory($0) } ?? []
        let user = ThemeLoader.loadDirectory(Self.userThemesDirectory)
        let merged = ThemeCatalog.merge(builtIn: builtIn, user: user) { NSLog("Margins themes: %@", $0) }
        if merged != themes { themes = merged }
    }

    func openThemesFolder() {
        let dir = Self.userThemesDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("Margins themes: could not create %@: %@", dir.path, error.localizedDescription)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        if source == nil { watchUserDirectory() }
    }

    /// Watches the user folder (not its parent) so adding, editing, or removing a theme reloads within a moment.
    private func watchUserDirectory() {
        let dir = Self.userThemesDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main
        )
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                if !FileManager.default.fileExists(atPath: Self.userThemesDirectory.path) {
                    self.source?.cancel()
                    self.source = nil
                }
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

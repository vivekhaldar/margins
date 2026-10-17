import AppKit
import MarginsCore
import SwiftUI
import UniformTypeIdentifiers

/// Routes application events to windows without sharing their document or editor state.
@MainActor
final class DocumentWindows {
    static let shared = DocumentWindows()
    lazy var settingsState = AppState()
    private var states: [ObjectIdentifier: AppState] = [:]
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var allocatedURLs: Set<URL> = []
    private var madeInitialWindow = false
    private let defaults: UserDefaults
    private var restoring: [URL: WindowSession.Window] = [:]
    private var activeRestoreURL: URL?
    private var pendingRegistrations = 0
    private var terminating = false
    private static let sessionKey = "openDocumentWindows"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private lazy var previousSession: WindowSession = {
        if let data = defaults.data(forKey: Self.sessionKey),
           let session = try? JSONDecoder().decode(WindowSession.self, from: data) {
            return session.restorable(canOpen: Self.canRestore)
        }
        // Migrate the single-document preference only when no window session exists.
        if defaults.object(forKey: Self.sessionKey) == nil,
           let url = defaults.url(forKey: "lastDocument"), Self.canRestore(url) {
            return WindowSession(windows: [.init(url: url, frame: "")])
        }
        return WindowSession()
    }()

    private static func canRestore(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? MarginsDocument.decode(data)) != nil
    }
    private var pendingURLs: [URL] = []
    var openWindow: ((URL) -> Void)? {
        didSet {
            guard let openWindow else { return }
            let queued = pendingURLs
            pendingURLs.removeAll()
            queued.forEach(openWindow)
        }
    }

    var keyState: AppState? {
        guard let window = NSApp.keyWindow else { return nil }
        return states[ObjectIdentifier(window)]
    }

    func makeState(url: URL?) -> AppState {
        var documentURL = url
        if !madeInitialWindow {
            let session = previousSession
            restoring = Dictionary(uniqueKeysWithValues: session.windows.map { ($0.url.standardizedFileURL, $0) })
            activeRestoreURL = session.activeURL
            // Use the initial scene for one saved document; route the rest through openWindow.
            if documentURL == nil, pendingURLs.isEmpty, let first = session.windows.first {
                documentURL = first.url
            }
            pendingURLs += session.windows.map(\.url).filter {
                $0.standardizedFileURL != documentURL?.standardizedFileURL && !pendingURLs.contains($0)
            }
            madeInitialWindow = true
        }
        var untitled = AppState.newUntitledURL()
        var suffix = 2
        while allocatedURLs.contains(untitled) || FileManager.default.fileExists(atPath: untitled.path) {
            untitled = AppState.documentsFolder.appendingPathComponent("Untitled \(suffix).margins")
            suffix += 1
        }
        allocatedURLs.insert(untitled)
        let state = AppState(untitledURL: untitled)
        if let documentURL {
            state.open(documentURL)
            // A file can disappear between validating the session and constructing its scene.
            if state.fileURL.standardizedFileURL != documentURL.standardizedFileURL {
                restoring.removeValue(forKey: documentURL.standardizedFileURL)
                if activeRestoreURL == documentURL.standardizedFileURL { activeRestoreURL = nil }
            }
        }
        return state
    }

    func register(_ window: NSWindow, state: AppState) {
        let id = ObjectIdentifier(window)
        guard states[id] == nil else { return }
        states[id] = state
        windows[id] = window
        // Own restoration explicitly so the system's Resume preference cannot create duplicates.
        window.isRestorable = false
        let saved = restoring.removeValue(forKey: state.fileURL.standardizedFileURL)
        pendingRegistrations += 1
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.pendingRegistrations -= 1
            guard let window, self.states[id] != nil else {
                self.persistSession()
                return
            }
            if let saved {
                let frame = NSRectFromString(saved.frame)
                if frame.width >= 900, frame.height >= 560,
                   NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
                } else {
                    window.center()
                }
                if saved.miniaturized { window.miniaturize(nil) }
            }
            if self.restoring.isEmpty, self.pendingRegistrations == 0, let active = self.activeRestoreURL {
                self.activeRestoreURL = nil
                if let entry = self.states.first(where: { $0.value.fileURL.standardizedFileURL == active }),
                   let front = self.windows[entry.key], !front.isMiniaturized {
                    front.makeKeyAndOrderFront(nil)
                }
            }
            state.saveNow(includeEmpty: true)
            self.persistSession()
        }
    }

    func persistSession() {
        guard madeInitialWindow, restoring.isEmpty, pendingRegistrations == 0, !terminating else { return }
        var ordered = Array(NSApp.orderedWindows.reversed()).filter { states[ObjectIdentifier($0)] != nil }
        // Minimized windows may be absent from AppKit's on-screen ordering.
        let included = Set(ordered.map(ObjectIdentifier.init))
        ordered.insert(contentsOf: windows.values.filter { !included.contains(ObjectIdentifier($0)) }, at: 0)
        let entries = ordered.compactMap { window -> WindowSession.Window? in
            guard let state = states[ObjectIdentifier(window)] else { return nil }
            return .init(url: state.fileURL, frame: NSStringFromRect(window.frame), miniaturized: window.isMiniaturized)
        }
        let session = WindowSession(windows: entries, activeURL: keyState?.fileURL)
        if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: Self.sessionKey) }
    }

    /// Snapshot before AppKit starts closing windows during Quit.
    func prepareToQuit() async {
        let openStates = Array(states.values)
        for state in openStates { state.stopAll() }
        for state in openStates {
            await state.editor.flushForSave()
            state.saveNow(includeEmpty: true)
        }
        persistSession()
        terminating = true
    }

    func close(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let state = states.removeValue(forKey: id) else { return }
        windows[id] = nil
        state.saveNow()
        state.stopAll()
        state.shutdownProviders()
        persistSession()
    }

    func open(_ url: URL) {
        if let entry = states.first(where: { $0.value.fileURL.standardizedFileURL == url.standardizedFileURL }) {
            windows[entry.key]?.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(url)
        } else {
            pendingURLs.append(url)
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: MarginsDocument.fileExtension) ?? .json]
        panel.directoryURL = AppState.documentsFolder
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    func shutdown() {
        for state in states.values {
            state.saveNow()
            state.stopAll()
            state.shutdownProviders()
        }
        settingsState.shutdownProviders()
    }
}

struct DocumentWindow: View {
    @StateObject private var state: AppState
    @Binding private var url: URL?
    @Environment(\.openWindow) private var openWindow

    init(url: Binding<URL?>) {
        _url = url
        _state = StateObject(wrappedValue: DocumentWindows.shared.makeState(url: url.wrappedValue))
    }

    var body: some View {
        ContentView()
            .environmentObject(state)
            .focusedSceneObject(state)
            .frame(minWidth: 900, minHeight: 560)
            .background(WindowRegistration(state: state))
            .onReceive(state.$fileURL) {
                url = $0
                // @Published emits before the property changes; read the settled URL next turn.
                DispatchQueue.main.async { DocumentWindows.shared.persistSession() }
            }
            .onAppear {
                DocumentWindows.shared.openWindow = { url in openWindow(id: "document", value: url) }
            }
    }
}

private struct WindowRegistration: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> RegistrationView { RegistrationView(state: state) }
    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        let state: AppState
        init(state: AppState) {
            self.state = state
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DocumentWindows.shared.register(window, state: state)
        }
    }
}

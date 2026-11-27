import AppKit
import Foundation
import MarginsCore
import SwiftUI

/// A tool call waiting for the author's go-ahead, shown on its instruction card.
struct PermissionAsk: Identifiable {
    let request: PermissionRequest
    let step: Int
    let resume: (PermissionDecision) -> Void
    var id: String { request.id }
}

struct PendingInfo: Equatable {
    var total = 0
    var byStep: [Int: Int] = [:]
    var selected = 0
}

@MainActor
final class AppState: ObservableObject {
    @Published var doc = MarginsDocument() { didSet { scheduleThreads() } }
    @Published var fileURL: URL
    @Published var pending = PendingInfo() { didSet { scheduleThreads() } }
    @Published var inFlight = 0
    @Published var previewing: Version?
    @Published var showHistory = false
    @Published var showOutline = true {
        didSet {
            defaults.set(showOutline, forKey: "showOutline")
            let on = showOutline
            Task { await editor.setOutline(on) }
        }
    }
    @Published var hoveredStep: Int?
    /// A provenance inspector can reveal the exact instruction that produced a range.
    @Published var revealedIntentID: UUID?
    @Published var instructionRevealRequest = UUID()
    /// What the backend agent may do (web, commands, files). Persisted.
    @Published var toolPolicy: AgentToolPolicy = .research {
        didSet { defaults.set(toolPolicy.rawValue, forKey: "toolPolicy") }
    }
    /// Latest reasoning/narration per working instruction (not persisted).
    @Published var liveThought: [Int: String] = [:] { didSet { scheduleThreads() } }
    /// Tool calls awaiting approval, per instruction step.
    @Published var permissionAsks: [Int: PermissionAsk] = [:] { didSet { scheduleThreads() } }
    var threadsPush: Task<Void, Never>?
    var lastThreadsJSON = ""
    var running: [Int: Task<Void, Never>] = [:]
    var documentSessionID = UUID()
    var activeRunIDs: [Int: UUID] = [:]
    var lastRunsJSON = ""
    /// Steps whose next thought starts a fresh paragraph (a tool call happened since the last one).
    var thoughtBreak: Set<Int> = []
    @Published var lastError: String?

    @Published var providers: [ProviderConfig] { didSet { persistProviders() } }
    @Published var activeProviderID: UUID { didSet { defaults.set(activeProviderID.uuidString, forKey: "activeProvider") } }
    @Published var models: [UUID: [ModelInfo]] = [:]
    @Published private(set) var zoom: Double = 1.0
    @Published var fontPreferences: FontPreferences {
        didSet {
            guard fontPreferences != oldValue else { return }
            persistFontPreferences()
            applyFontsToEditor()
        }
    }

    let editor = EditorBridge()
    var instances: [UUID: (config: ProviderConfig, provider: ModelProvider)] = [:]
    let defaults: UserDefaults
    var saveTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?
    private var projectFolderObserver: NSObjectProtocol?
    let projectFolderStore: ProjectFolderStore
    var fileWatcher: FileChangeWatcher?
    @Published var projectFolderRevision = 0

    // Copilot Cloud Agent state (logic in AppState+CloudAgents.swift)
    @Published var composerTarget: ComposerTarget = .local {
        didSet {
            let isCloud = composerTarget == .cloud
            Task { await editor.setCloudMode(isCloud) }
        }
    }
    @Published var cloudRepo = ""
    @Published var cloudBaseRef = "main"
    @Published var cloudCreatePR = false
    @Published var cloudAuthStatus: CopilotCloudAuthStatus?
    @Published var cloudDirtyFilesCount = 0
    @Published var cloudLogs: [UUID: String] = [:]
    @Published var cloudStreamingIntentIDs: Set<UUID> = []
    var cloudPollTasks: [UUID: Task<Void, Never>] = [:]
    var cloudLogTasks: [UUID: Task<Void, Never>] = [:]
    var cloudNotifiedAttention: Set<UUID> = []
    let cloudClient = CopilotCloudClient()

    init(restoreLastDocument: Bool = false, untitledURL: URL? = nil, defaults: UserDefaults = .standard,
         projectFolderStore: ProjectFolderStore = .shared) {
        self.defaults = defaults
        self.projectFolderStore = projectFolderStore
        let ud = defaults
        var list = ProviderConfig.defaults
        if let data = ud.data(forKey: "providers"),
           let stored = try? JSONDecoder().decode([ProviderConfig].self, from: data), !stored.isEmpty {
            list = stored
        }
        let saved = ud.string(forKey: "activeProvider").flatMap(UUID.init(uuidString:))
        providers = list
        activeProviderID = list.first { $0.id == saved }?.id ?? list.first { $0.enabled }?.id ?? list[0].id
        if let data = ud.data(forKey: "fontPreferences"),
           let storedFonts = try? JSONDecoder().decode(FontPreferences.self, from: data) {
            fontPreferences = storedFonts
        } else {
            fontPreferences = FontPreferences()
        }
        fileURL = untitledURL ?? Self.newUntitledURL()

        editor.onMessage = { [weak self] type, body in self?.handle(type, body) }
        editor.assetLookup = { [weak self] id in self?.doc.assets[id] }
        editor.onAddAsset = { [weak self] data, mime in self?.doc.addAsset(data, mime: mime) }
        if ud.object(forKey: "showOutline") != nil { showOutline = ud.bool(forKey: "showOutline") }
        if let p = ud.string(forKey: "toolPolicy").flatMap(AgentToolPolicy.init(rawValue:)) { toolPolicy = p }
        let savedZoom = ud.double(forKey: "zoom")
        setZoom(savedZoom > 0 ? savedZoom : 1.0)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: ud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadProviderSettings()
                self?.reloadFontPreferences()
            }
        }
        projectFolderObserver = NotificationCenter.default.addObserver(
            forName: ProjectFolderStore.didChangeNotification, object: projectFolderStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.projectFolderRevision += 1
            }
        }

        if restoreLastDocument, let last = defaults.url(forKey: "lastDocument"), FileManager.default.fileExists(atPath: last.path) {
            open(last)
        }
        startWatchingCurrentFile()
        resumeCloudPolling()
        refreshCloudContext()
    }

    deinit {
        fileWatcher?.stop()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let projectFolderObserver { NotificationCenter.default.removeObserver(projectFolderObserver) }
    }

    // MARK: - zoom

    private static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ z: Double) {
        zoom = min(max(z, 0.5), 3.0)
        editor.webView.pageZoom = zoom
        defaults.set(zoom, forKey: "zoom")
    }

}

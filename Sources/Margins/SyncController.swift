import AppKit
import Foundation
import MarginsCore
import SwiftUI

/// App-level coordinator for Google Drive sync: manages OAuth sign-in, background polling,
/// debounced pushes after autosave, quit flushing, and library index updates.
@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController()

    private static let configKey = "googleDriveOAuthConfig"
    private static let onboardingDismissedKey = "syncOnboardingDismissed"
    static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margins", isDirectory: true)
        return support.appendingPathComponent("sync-index.json")
    }

    @Published var oauthConfig: GoogleOAuthConfig {
        didSet {
            guard oauthConfig != oldValue else { return }
            persistConfig()
            let cfg = oauthConfig
            Task { await oauth.updateConfig(cfg) }
        }
    }
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var status: SyncStatus = .disconnected
    @Published private(set) var index: SyncIndex
    @Published var lastError: String?
    @Published var isSigningIn = false
    @Published var showOnboarding = false

    private let defaults: UserDefaults
    private let oauth: GoogleOAuthClient
    private let backend: GoogleDriveBackend
    private let engine: SyncEngine
    private var pollTask: Task<Void, Never>?
    private var pushTasks: [URL: Task<Void, Never>] = [:]
    private var activeObserver: NSObjectProtocol?
    private var activeLoopback: LoopbackOAuthServer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedConfig: GoogleOAuthConfig
        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(GoogleOAuthConfig.self, from: data) {
            loadedConfig = decoded
        } else {
            loadedConfig = GoogleOAuthConfig()
        }
        self.oauthConfig = loadedConfig
        let tokenStore = KeychainTokenStore()
        self.oauth = GoogleOAuthClient(config: loadedConfig, tokenStore: tokenStore)
        self.backend = GoogleDriveBackend(oauth: oauth)
        self.index = SyncIndex.load(from: Self.indexURL)
        self.engine = SyncEngine(
            backend: backend,
            documentsFolder: AppState.documentsFolder,
            indexURL: Self.indexURL,
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )

        let connected = tokenStore.load() != nil
        self.isConnected = connected
        self.status = connected ? .synced(index.lastSyncedAt) : .disconnected
        self.showOnboarding = !connected && !defaults.bool(forKey: Self.onboardingDismissedKey)

        Task {
            await engine.setEventHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            }
            if connected {
                startBackgroundPolling()
                await syncNow()
            } else {
                _ = await engine.scanLocalLibrary()
            }
        }

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                await self.syncNow()
            }
        }
    }

    deinit {
        pollTask?.cancel()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    // MARK: - Connection

    func connectGoogleDrive() {
        guard !isSigningIn else { return }
        guard oauthConfig.isConfigured else {
            lastError = "Enter a Google OAuth Client ID in Settings → Sync first."
            return
        }
        isSigningIn = true
        lastError = nil

        Task {
            do {
                let server = try LoopbackOAuthServer()
                activeLoopback = server
                let pkce = PKCE()
                let authURL = try await oauth.authorizationURL(redirectURI: server.redirectURI, pkce: pkce)
                NSWorkspace.shared.open(authURL)

                let code = try await server.waitForCode(expectedState: pkce.state, timeout: 300)
                activeLoopback = nil
                _ = try await oauth.exchangeCode(code, redirectURI: server.redirectURI, codeVerifier: pkce.codeVerifier)

                isConnected = true
                isSigningIn = false
                dismissOnboarding()

                let uploadExisting = promptInitialUploadIfNeeded()
                startBackgroundPolling()
                _ = await engine.syncAll(uploadExistingLocal: uploadExisting)
            } catch {
                activeLoopback?.close()
                activeLoopback = nil
                isSigningIn = false
                lastError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        activeLoopback?.close()
        activeLoopback = nil
        isSigningIn = false
    }

    func disconnectGoogleDrive() {
        pollTask?.cancel()
        pollTask = nil
        for task in pushTasks.values { task.cancel() }
        pushTasks.removeAll()
        isConnected = false
        status = .disconnected
        Task {
            await oauth.disconnect()
            await engine.resetSyncState()
        }
    }

    func dismissOnboarding() {
        showOnboarding = false
        defaults.set(true, forKey: Self.onboardingDismissedKey)
    }

    // MARK: - Syncing

    func syncNow() async {
        guard isConnected else { return }
        _ = await engine.syncAll()
    }

    func schedulePush(for url: URL) {
        let standardized = url.standardizedFileURL
        guard isConnected, isInSyncedLibrary(standardized) else { return }
        pushTasks[standardized]?.cancel()
        pushTasks[standardized] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pushTasks[standardized] = nil
            _ = await self.engine.pushDocument(at: standardized)
        }
    }

    /// Flushes any pending debounced uploads before the app terminates.
    func flushPendingPushes() async {
        guard isConnected else { return }
        let pendingURLs = Array(pushTasks.keys)
        for task in pushTasks.values { task.cancel() }
        pushTasks.removeAll()
        for url in pendingURLs {
            _ = await engine.pushDocument(at: url)
        }
    }

    func isInSyncedLibrary(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == AppState.documentsFolder.standardizedFileURL
    }

    func entry(for docID: UUID) -> SyncEntry? {
        index.entry(for: docID)
    }

    func refreshLocalLibrary() {
        Task { _ = await engine.scanLocalLibrary() }
    }

    func openFromLibrary(_ entry: SyncEntry) async {
        let localURL = entry.localURL(in: AppState.documentsFolder)
        if entry.state != .cloudOnly, FileManager.default.fileExists(atPath: localURL.path) {
            DocumentWindows.shared.open(localURL)
            return
        }
        do {
            let downloaded = try await engine.ensureLocal(docID: entry.docID)
            DocumentWindows.shared.open(downloaded)
        } catch {
            lastError = "Couldn't download “\(entry.title)”: \(error.localizedDescription)"
        }
    }

    func clearConflict(for docID: UUID) {
        Task { await engine.clearConflict(for: docID) }
    }

    func moveToSyncedLibrary(state: AppState) {
        let source = state.fileURL.standardizedFileURL
        guard !isInSyncedLibrary(source) else { return }
        Task {
            await state.flushAndSave(includeEmpty: true)
            let stem = source.deletingPathExtension().lastPathComponent
            let dest = AppState.uniqueURL(named: stem)
            do {
                try FileManager.default.copyItem(at: source, to: dest)
                let srcMD = source.deletingPathExtension().appendingPathExtension("md")
                let dstMD = dest.deletingPathExtension().appendingPathExtension("md")
                if FileManager.default.fileExists(atPath: srcMD.path) {
                    try? FileManager.default.copyItem(at: srcMD, to: dstMD)
                }
                state.open(dest)
                if isConnected {
                    _ = await engine.pushDocument(at: dest)
                }
            } catch {
                lastError = "Couldn't copy to Margins Library: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Private

    private func startBackgroundPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, let self, self.isConnected else { break }
                _ = await self.engine.syncAll()
            }
        }
    }

    private func promptInitialUploadIfNeeded() -> Bool {
        let existing = ((try? FileManager.default.contentsOfDirectory(at: AppState.documentsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == MarginsDocument.fileExtension }
        guard !existing.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "Upload existing documents to Google Drive?"
        alert.informativeText = "Found \(existing.count) local document\(existing.count == 1 ? "" : "s") in ~/Documents/Margins. Margins will upload them to your Drive’s Margins folder and deduplicate by document ID."
        alert.addButton(withTitle: "Upload Existing Documents")
        alert.addButton(withTitle: "Sync New Edits Only")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .statusChanged(let newStatus):
            status = newStatus
        case .indexUpdated(let newIndex):
            index = newIndex
        case .documentPulled(_, let url):
            DocumentWindows.shared.reloadOpenWindowIfNeeded(at: url)
        case .conflictCreated:
            break
        }
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(oauthConfig) {
            defaults.set(data, forKey: Self.configKey)
        }
    }
}

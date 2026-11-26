import CryptoKit
import Foundation

public enum SyncStatus: Equatable, Sendable {
    case disconnected
    case synced(Date?)
    case syncing
    case offline(pendingCount: Int)
    case conflict(count: Int)
    case error(String)

    public var label: String {
        switch self {
        case .disconnected: return "Local"
        case .synced: return "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .conflict(let count): return count > 1 ? "\(count) Conflicts" : "Conflict"
        case .error: return "Sync Error"
        }
    }
}

public enum SyncEvent: Sendable {
    case statusChanged(SyncStatus)
    case indexUpdated(SyncIndex)
    case documentPulled(docID: UUID, url: URL)
    case conflictCreated(docID: UUID, localURL: URL, conflictURL: URL)
}

/// Local-first background sync engine coordinating `~/Documents/Margins/*.margins`,
/// `sync-index.json`, and a pluggable `SyncBackend` (Google Drive).
public actor SyncEngine {
    let backend: SyncBackend
    public let documentsFolder: URL
    public let indexURL: URL
    let hostName: String
    let now: @Sendable () -> Date
    var onEvent: (@Sendable (SyncEvent) -> Void)?

    public internal(set) var index: SyncIndex
    public private(set) var status: SyncStatus = .disconnected
    private var isSyncing = false

    public init(backend: SyncBackend,
                documentsFolder: URL,
                indexURL: URL,
                hostName: String = ProcessInfo.processInfo.hostName,
                now: @escaping @Sendable () -> Date = { Date() },
                onEvent: (@Sendable (SyncEvent) -> Void)? = nil) {
        self.backend = backend
        self.documentsFolder = documentsFolder.standardizedFileURL
        self.indexURL = indexURL.standardizedFileURL
        self.hostName = hostName
        self.now = now
        self.onEvent = onEvent
        self.index = SyncIndex.load(from: indexURL)
    }

    public func setEventHandler(_ handler: (@Sendable (SyncEvent) -> Void)?) {
        self.onEvent = handler
    }

    public func currentIndex() -> SyncIndex { index }
    public func currentStatus() -> SyncStatus { status }

    /// Scans `documentsFolder` for `.margins` files, updating `sync-index.json` by `doc.id`.
    @discardableResult
    public func scanLocalLibrary() -> SyncIndex {
        do { return try scanLibrary() }
        catch {
            updateStatus(.error(error.localizedDescription))
            return index
        }
    }

    private func scanLibrary() throws -> SyncIndex {
        let fm = FileManager.default
        try fm.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        let urls = try fm.contentsOfDirectory(at: documentsFolder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == MarginsDocument.fileExtension }

        var seenIDs = Set<UUID>()
        for url in urls {
            let file: SyncDocument
            do { file = try SyncDocument.load(at: url, index: index) }
            catch is DecodingError { continue }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            let doc = file.document
            seenIDs.insert(doc.id)
            let hash = Self.sha256Hex(file.data)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
            let filename = url.lastPathComponent

            if var existing = index.entry(for: doc.id) {
                let changed = existing.lastSyncedContentHash != hash || existing.filename != filename
                existing.filename = filename
                existing.title = doc.title
                existing.modifiedAt = mtime
                if existing.state != .conflict {
                    existing.state = changed ? .pendingUpload : .synced
                }
                index.setEntry(existing)
            } else {
                index.setEntry(SyncEntry(
                    docID: doc.id,
                    filename: filename,
                    title: doc.title,
                    modifiedAt: mtime,
                    state: .pendingUpload
                ))
            }
        }

        // Clean up local-only entries whose files were removed from disk.
        for (key, entry) in index.entries where !seenIDs.contains(entry.docID) {
            if entry.driveFileId == nil {
                index.entries.removeValue(forKey: key)
            } else if entry.state != .cloudOnly && entry.state != .downloading {
                var updated = entry
                updated.state = .cloudOnly
                index.entries[key] = updated
            }
        }

        persistIndex()
        return index
    }

    /// Runs a full pull + push cycle. Set `uploadExistingLocal: false` on first connect if the user
    /// chose not to upload pre-existing local documents. Set `lazyDownload: true` to index new remote
    /// documents as `.cloudOnly` without downloading their full JSON immediately.
    @discardableResult
    public func syncAll(uploadExistingLocal: Bool = true, lazyDownload: Bool = false) async -> SyncStatus {
        guard !isSyncing else { return status }
        isSyncing = true
        updateStatus(.syncing)
        defer { isSyncing = false }

        do {
            _ = try scanLibrary()
            let folderID: String
            if let existingFolder = index.folderID {
                folderID = existingFolder
            } else {
                folderID = try await backend.ensureRootFolder()
                index.folderID = folderID
                persistIndex()
            }

            if index.startPageToken == nil {
                try await performInitialPull(folderID: folderID, lazyDownload: lazyDownload)
            } else {
                try await performIncrementalPull(folderID: folderID, lazyDownload: lazyDownload)
            }

            // Push pending local documents.
            let entriesToPush = index.entries.values.filter { entry in
                guard entry.state == .pendingUpload else { return false }
                if entry.driveFileId != nil { return true }
                return uploadExistingLocal
            }
            for entry in entriesToPush {
                try await pushEntry(entry, folderID: folderID)
            }

            index.lastSyncedAt = now()
            persistIndex()
            let finalStatus = computeSettledStatus()
            updateStatus(finalStatus)
            return finalStatus
        } catch {
            return handleSyncError(error)
        }
    }

    /// Pushes a single local `.margins` file (called after debounced autosave).
    @discardableResult
    public func pushDocument(at url: URL) async -> SyncStatus {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == documentsFolder else {
            return status
        }
        let file: SyncDocument
        do { file = try SyncDocument.load(at: standardized, index: index) }
        catch is DecodingError { return status }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return status }
        catch {
            updateStatus(.error(error.localizedDescription))
            return status
        }
        let doc = file.document
        let hash = Self.sha256Hex(file.data)
        let filename = standardized.lastPathComponent
        var entry = index.entry(for: doc.id) ?? SyncEntry(
            docID: doc.id,
            filename: filename,
            title: doc.title,
            modifiedAt: now(),
            state: .pendingUpload
        )
        entry.filename = filename
        entry.title = doc.title
        entry.modifiedAt = now()
        if entry.lastSyncedContentHash == hash && entry.driveFileId != nil && entry.state == .synced {
            return status
        }
        entry.state = .pendingUpload
        index.setEntry(entry)
        persistIndex()

        guard !isSyncing else { return status }
        isSyncing = true
        updateStatus(.syncing)
        defer { isSyncing = false }

        do {
            let folderID: String
            if let existing = index.folderID {
                folderID = existing
            } else {
                folderID = try await backend.ensureRootFolder()
                index.folderID = folderID
            }
            try await pushEntry(entry, folderID: folderID)
            index.lastSyncedAt = now()
            persistIndex()
            let settled = computeSettledStatus()
            updateStatus(settled)
            return settled
        } catch {
            return handleSyncError(error)
        }
    }

    /// Downloads a `.cloudOnly` document on demand (for example, when opened from the library picker).
    public func ensureLocal(docID: UUID) async throws -> URL {
        guard var entry = index.entry(for: docID) else {
            throw SyncError.invalidResponse("Document not found in sync index.")
        }
        let targetURL = entry.localURL(in: documentsFolder)
        if FileManager.default.fileExists(atPath: targetURL.path), entry.state != .cloudOnly {
            return targetURL
        }
        guard let fileID = entry.driveFileId else {
            throw SyncError.invalidResponse("Document has no remote Drive file ID.")
        }

        entry.state = .downloading
        index.setEntry(entry)
        persistIndex()

        let file = try SyncDocument(await backend.download(fileID: fileID)) { docID }
        let data = file.data
        let doc = file.document
        try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        try data.write(to: targetURL, options: .atomic)
        Self.regenerateMarkdown(for: doc, at: targetURL)

        entry.title = doc.title
        entry.lastSyncedContentHash = Self.sha256Hex(data)
        entry.modifiedAt = now()
        entry.state = .synced
        index.setEntry(entry)
        persistIndex()
        onEvent?(.documentPulled(docID: docID, url: targetURL))
        return targetURL
    }

    public func clearConflict(for docID: UUID) {
        guard var entry = index.entry(for: docID), entry.state == .conflict else { return }
        entry.state = .synced
        entry.conflictFilename = nil
        index.setEntry(entry)
        persistIndex()
        updateStatus(computeSettledStatus())
    }

    public func resetSyncState() {
        index = SyncIndex()
        try? FileManager.default.removeItem(at: indexURL)
        updateStatus(.disconnected)
        onEvent?(.indexUpdated(index))
    }

    // MARK: - Status & Persistence

    private func handleSyncError(_ error: Error) -> SyncStatus {
        persistIndex()
        let next: SyncStatus
        if let err = error as? SyncError, err.isOffline {
            next = .offline(pendingCount: index.pendingUploadCount)
        } else {
            next = .error(error.localizedDescription)
        }
        updateStatus(next)
        return next
    }

    func computeSettledStatus() -> SyncStatus {
        let conflicts = index.conflictCount
        if conflicts > 0 { return .conflict(count: conflicts) }
        return .synced(index.lastSyncedAt)
    }

    func persistIndex() {
        try? index.save(to: indexURL)
        onEvent?(.indexUpdated(index))
    }

    func updateStatus(_ newStatus: SyncStatus) {
        status = newStatus
        onEvent?(.statusChanged(newStatus))
    }
}

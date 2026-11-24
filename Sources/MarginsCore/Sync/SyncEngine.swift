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
    private let backend: SyncBackend
    public let documentsFolder: URL
    public let indexURL: URL
    private let hostName: String
    private let now: @Sendable () -> Date
    private var onEvent: (@Sendable (SyncEvent) -> Void)?

    public private(set) var index: SyncIndex
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
        let fm = FileManager.default
        try? fm.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        let urls = ((try? fm.contentsOfDirectory(at: documentsFolder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == MarginsDocument.fileExtension }

        var seenIDs = Set<UUID>()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? MarginsDocument.decode(data) else { continue }
            seenIDs.insert(doc.id)
            let hash = Self.sha256Hex(data)
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
            scanLocalLibrary()
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
        } catch let err as SyncError {
            persistIndex()
            if err.isOffline {
                let s = SyncStatus.offline(pendingCount: index.pendingUploadCount)
                updateStatus(s)
                return s
            }
            let s = SyncStatus.error(err.localizedDescription)
            updateStatus(s)
            return s
        } catch {
            persistIndex()
            let s = SyncStatus.error(error.localizedDescription)
            updateStatus(s)
            return s
        }
    }

    /// Pushes a single local `.margins` file (called after debounced autosave).
    @discardableResult
    public func pushDocument(at url: URL) async -> SyncStatus {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == documentsFolder else {
            return status
        }
        guard let data = try? Data(contentsOf: standardized),
              let doc = try? MarginsDocument.decode(data) else {
            return status
        }

        let hash = Self.sha256Hex(data)
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
        } catch let err as SyncError {
            persistIndex()
            if err.isOffline {
                let s = SyncStatus.offline(pendingCount: index.pendingUploadCount)
                updateStatus(s)
                return s
            }
            let s = SyncStatus.error(err.localizedDescription)
            updateStatus(s)
            return s
        } catch {
            persistIndex()
            let s = SyncStatus.error(error.localizedDescription)
            updateStatus(s)
            return s
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

        let data = try await backend.download(fileID: fileID)
        let doc = try MarginsDocument.decode(data)
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

    // MARK: - Pull

    private func performInitialPull(folderID: String, lazyDownload: Bool) async throws {
        let startToken = try await backend.getStartPageToken()
        let remoteFiles = try await backend.listFiles(folderID: folderID)
        for remote in remoteFiles where !remote.trashed && remote.name.hasSuffix(".\(MarginsDocument.fileExtension)") {
            try await reconcileRemoteFile(remote, lazyDownload: lazyDownload)
        }
        index.startPageToken = startToken
        persistIndex()
    }

    private func performIncrementalPull(folderID: String, lazyDownload: Bool) async throws {
        guard let token = index.startPageToken else { return }
        let page = try await backend.listChanges(pageToken: token, folderID: folderID)
        // Coalesce multiple changes for the same fileId within a page, keeping the latest state.
        var latestByFileID: [String: RemoteChange] = [:]
        var orderedFileIDs: [String] = []
        for change in page.changes {
            if latestByFileID[change.fileId] == nil {
                orderedFileIDs.append(change.fileId)
            }
            latestByFileID[change.fileId] = change
        }
        for fileId in orderedFileIDs {
            guard let change = latestByFileID[fileId] else { continue }
            if change.removed {
                if let entry = index.entry(forDriveFileId: change.fileId) {
                    let localURL = entry.localURL(in: documentsFolder)
                    if !FileManager.default.fileExists(atPath: localURL.path) {
                        index.removeEntry(for: entry.docID)
                    } else {
                        var detached = entry
                        detached.driveFileId = nil
                        detached.lastSyncedRevision = nil
                        index.setEntry(detached)
                    }
                }
                continue
            }
            guard let remote = change.file,
                  !remote.trashed,
                  remote.name.hasSuffix(".\(MarginsDocument.fileExtension)") else { continue }
            try await reconcileRemoteFile(remote, lazyDownload: lazyDownload)
        }
        index.startPageToken = page.newStartPageToken
        persistIndex()
    }

    private func reconcileRemoteFile(_ remote: RemoteFile, lazyDownload: Bool) async throws {
        let existingEntry = remote.docID.flatMap { index.entry(for: $0) } ?? index.entry(forDriveFileId: remote.id)

        // Already up to date on this revision: handle remote rename if needed.
        if var entry = existingEntry,
           let rev = remote.headRevisionId,
           entry.lastSyncedRevision == rev {
            if entry.filename != remote.name, entry.state == .synced {
                renameLocalFile(entry: &entry, to: remote.name)
                index.setEntry(entry)
            }
            return
        }

        // New remote document not yet on disk.
        if existingEntry == nil, lazyDownload, let docID = remote.docID {
            let title = (remote.name as NSString).deletingPathExtension
            let entry = SyncEntry(
                docID: docID,
                driveFileId: remote.id,
                lastSyncedRevision: remote.headRevisionId,
                lastSyncedContentHash: nil,
                filename: remote.name,
                title: title,
                modifiedAt: remote.modifiedTime ?? now(),
                state: .cloudOnly
            )
            index.setEntry(entry)
            return
        }

        let remoteData = try await backend.download(fileID: remote.id)
        let remoteDoc = try MarginsDocument.decode(remoteData)
        let remoteHash = Self.sha256Hex(remoteData)
        let docID = remote.docID ?? remoteDoc.id

        if var entry = index.entry(for: docID) {
            let localURL = entry.localURL(in: documentsFolder)
            let localData = try? Data(contentsOf: localURL)
            let localHash = localData.map(Self.sha256Hex)

            if localHash == remoteHash {
                // Identical content (e.g. initial deduplication by doc.id).
                entry.driveFileId = remote.id
                entry.lastSyncedRevision = remote.headRevisionId
                entry.lastSyncedContentHash = remoteHash
                entry.title = remoteDoc.title
                entry.modifiedAt = remote.modifiedTime ?? entry.modifiedAt
                entry.state = .synced
                index.setEntry(entry)
                return
            }

            let hasUnsyncedLocalEdits = localData != nil && localHash != entry.lastSyncedContentHash
            if hasUnsyncedLocalEdits, let localData {
                let conflictURL = try writeConflictCopy(localData: localData, title: entry.title)
                try remoteData.write(to: localURL, options: .atomic)
                Self.regenerateMarkdown(for: remoteDoc, at: localURL)
                entry.driveFileId = remote.id
                entry.lastSyncedRevision = remote.headRevisionId
                entry.lastSyncedContentHash = remoteHash
                entry.title = remoteDoc.title
                entry.modifiedAt = remote.modifiedTime ?? now()
                entry.state = .conflict
                entry.conflictFilename = conflictURL.lastPathComponent
                index.setEntry(entry)
                onEvent?(.conflictCreated(docID: docID, localURL: localURL, conflictURL: conflictURL))
                onEvent?(.documentPulled(docID: docID, url: localURL))
                return
            }

            // Clean remote update.
            if entry.filename != remote.name {
                renameLocalFile(entry: &entry, to: remote.name)
            }
            let targetURL = entry.localURL(in: documentsFolder)
            try remoteData.write(to: targetURL, options: .atomic)
            Self.regenerateMarkdown(for: remoteDoc, at: targetURL)
            entry.driveFileId = remote.id
            entry.lastSyncedRevision = remote.headRevisionId
            entry.lastSyncedContentHash = remoteHash
            entry.title = remoteDoc.title
            entry.modifiedAt = remote.modifiedTime ?? now()
            entry.state = .synced
            index.setEntry(entry)
            onEvent?(.documentPulled(docID: docID, url: targetURL))
        } else {
            // Brand new remote document.
            let targetURL = uniqueLocalURL(preferredName: remote.name)
            try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
            try remoteData.write(to: targetURL, options: .atomic)
            Self.regenerateMarkdown(for: remoteDoc, at: targetURL)
            let entry = SyncEntry(
                docID: docID,
                driveFileId: remote.id,
                lastSyncedRevision: remote.headRevisionId,
                lastSyncedContentHash: remoteHash,
                filename: targetURL.lastPathComponent,
                title: remoteDoc.title,
                modifiedAt: remote.modifiedTime ?? now(),
                state: .synced
            )
            index.setEntry(entry)
            onEvent?(.documentPulled(docID: docID, url: targetURL))
        }
    }

    // MARK: - Push

    private func pushEntry(_ entry: SyncEntry, folderID: String) async throws {
        let localURL = entry.localURL(in: documentsFolder)
        guard let localData = try? Data(contentsOf: localURL),
              let localDoc = try? MarginsDocument.decode(localData) else { return }
        let localHash = Self.sha256Hex(localData)

        // V1 conflict check: before uploading over an existing Drive file, verify headRevisionId.
        if let fileID = entry.driveFileId, let expectedRev = entry.lastSyncedRevision {
            if let remoteMeta = try await backend.getMetadata(fileID: fileID),
               !remoteMeta.trashed,
               let remoteRev = remoteMeta.headRevisionId,
               remoteRev != expectedRev {
                let remoteData = try await backend.download(fileID: fileID)
                let remoteHash = Self.sha256Hex(remoteData)
                if remoteHash != localHash {
                    let remoteDoc = try MarginsDocument.decode(remoteData)
                    let conflictURL = try writeConflictCopy(localData: localData, title: localDoc.title)
                    try remoteData.write(to: localURL, options: .atomic)
                    Self.regenerateMarkdown(for: remoteDoc, at: localURL)

                    var updated = entry
                    updated.lastSyncedRevision = remoteRev
                    updated.lastSyncedContentHash = remoteHash
                    updated.title = remoteDoc.title
                    updated.modifiedAt = remoteMeta.modifiedTime ?? now()
                    updated.state = .conflict
                    updated.conflictFilename = conflictURL.lastPathComponent
                    index.setEntry(updated)
                    onEvent?(.conflictCreated(docID: entry.docID, localURL: localURL, conflictURL: conflictURL))
                    onEvent?(.documentPulled(docID: entry.docID, url: localURL))
                    return
                }
            }
        }

        let uploaded = try await backend.upload(
            data: localData,
            name: entry.filename,
            docID: entry.docID,
            folderID: folderID,
            existingFileID: entry.driveFileId
        )

        var updated = entry
        updated.driveFileId = uploaded.id
        updated.lastSyncedRevision = uploaded.headRevisionId
        updated.lastSyncedContentHash = localHash
        updated.title = localDoc.title
        updated.modifiedAt = uploaded.modifiedTime ?? now()
        updated.state = .synced
        index.setEntry(updated)
    }

    // MARK: - Helpers

    private func writeConflictCopy(localData: Data, title: String) throws -> URL {
        let name = Self.conflictFilename(title: title, hostName: hostName, date: now())
        let url = uniqueLocalURL(preferredName: name)
        try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        try localData.write(to: url, options: .atomic)
        return url
    }

    public static func conflictFilename(title: String, hostName: String, date: Date) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = safeTitle.isEmpty ? "Untitled" : String(safeTitle.prefix(60))
        let shortHost = hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = shortHost.isEmpty ? "Mac" : shortHost
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return "\(baseTitle) (Conflict on \(host) \(df.string(from: date))).\(MarginsDocument.fileExtension)"
    }

    private func renameLocalFile(entry: inout SyncEntry, to newName: String) {
        let fm = FileManager.default
        let oldURL = entry.localURL(in: documentsFolder)
        let newURL = uniqueLocalURL(preferredName: newName)
        guard oldURL != newURL else { return }
        if fm.fileExists(atPath: oldURL.path) {
            try? fm.moveItem(at: oldURL, to: newURL)
            let oldMD = oldURL.deletingPathExtension().appendingPathExtension("md")
            let newMD = newURL.deletingPathExtension().appendingPathExtension("md")
            if fm.fileExists(atPath: oldMD.path) { try? fm.moveItem(at: oldMD, to: newMD) }
            let oldAssets = oldURL.deletingPathExtension().appendingPathExtension("assets")
            let newAssets = newURL.deletingPathExtension().appendingPathExtension("assets")
            if fm.fileExists(atPath: oldAssets.path) { try? fm.moveItem(at: oldAssets, to: newAssets) }
        }
        entry.filename = newURL.lastPathComponent
    }

    private func uniqueLocalURL(preferredName: String) -> URL {
        let fm = FileManager.default
        let candidate = documentsFolder.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let next = documentsFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }

    private static func regenerateMarkdown(for doc: MarginsDocument, at url: URL) {
        guard !doc.versions.isEmpty || !doc.html.isEmpty else { return }
        let mdURL = url.deletingPathExtension().appendingPathExtension("md")
        let assetsFolder = url.deletingPathExtension().appendingPathExtension("assets")
        let folderName = assetsFolder.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetsFolder.lastPathComponent
        let used = MarginsDocument.assetIDs(in: doc.html).filter { doc.assets[$0] != nil }
        let fm = FileManager.default
        if used.isEmpty {
            try? fm.removeItem(at: assetsFolder)
        } else {
            try? fm.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
            for id in used {
                if let asset = doc.assets[id] {
                    let assetURL = assetsFolder.appendingPathComponent("\(id).\(asset.fileExtension)")
                    if !fm.fileExists(atPath: assetURL.path) {
                        try? asset.data.write(to: assetURL, options: .atomic)
                    }
                }
            }
        }
        let md = MarkdownExporter.markdown(fromHTML: doc.html) { src in
            guard let id = MarginsDocument.assetID(fromSrc: src), let a = doc.assets[id] else { return src }
            return "\(folderName)/\(id).\(a.fileExtension)"
        }
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)
    }

    private func computeSettledStatus() -> SyncStatus {
        let conflicts = index.conflictCount
        if conflicts > 0 { return .conflict(count: conflicts) }
        return .synced(index.lastSyncedAt)
    }

    private func persistIndex() {
        try? index.save(to: indexURL)
        onEvent?(.indexUpdated(index))
    }

    private func updateStatus(_ newStatus: SyncStatus) {
        status = newStatus
        onEvent?(.statusChanged(newStatus))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

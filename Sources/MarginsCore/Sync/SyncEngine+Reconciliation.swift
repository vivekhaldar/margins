import Foundation

extension SyncEngine {
    // MARK: - Pull

    func performInitialPull(folderID: String, lazyDownload: Bool) async throws {
        let startToken = try await backend.getStartPageToken()
        let remoteFiles = try await backend.listFiles(folderID: folderID)
        for remote in remoteFiles where !remote.trashed && remote.name.hasSuffix(".\(MarginsDocument.fileExtension)") {
            try await reconcileRemoteFile(remote, lazyDownload: lazyDownload)
        }
        index.startPageToken = startToken
        persistIndex()
    }

    func performIncrementalPull(folderID: String, lazyDownload: Bool) async throws {
        guard let token = index.startPageToken else { return }
        let page = try await backend.listChanges(pageToken: token, folderID: folderID)
        let coalesced = Self.coalesceChanges(page.changes)
        for change in coalesced {
            if change.removed {
                handleRemovedRemoteFile(fileId: change.fileId)
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

    private static func coalesceChanges(_ changes: [RemoteChange]) -> [RemoteChange] {
        var latestByFileID: [String: RemoteChange] = [:]
        var orderedFileIDs: [String] = []
        for change in changes {
            if latestByFileID[change.fileId] == nil {
                orderedFileIDs.append(change.fileId)
            }
            latestByFileID[change.fileId] = change
        }
        return orderedFileIDs.compactMap { latestByFileID[$0] }
    }

    private func handleRemovedRemoteFile(fileId: String) {
        guard let entry = index.entry(forDriveFileId: fileId) else { return }
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
            let entry = SyncEntry(
                docID: docID,
                driveFileId: remote.id,
                lastSyncedRevision: remote.headRevisionId,
                lastSyncedContentHash: nil,
                filename: remote.name,
                title: (remote.name as NSString).deletingPathExtension,
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

        if let entry = index.entry(for: docID) {
            try reconcileExistingEntry(entry, remote: remote, remoteData: remoteData, remoteDoc: remoteDoc, remoteHash: remoteHash)
        } else {
            try saveNewRemoteDocument(docID: docID, remote: remote, remoteData: remoteData, remoteDoc: remoteDoc, remoteHash: remoteHash)
        }
    }

    private func reconcileExistingEntry(_ existing: SyncEntry,
                                        remote: RemoteFile,
                                        remoteData: Data,
                                        remoteDoc: MarginsDocument,
                                        remoteHash: String) throws {
        var entry = existing
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
            try applyConflict(
                entry: entry,
                localURL: localURL,
                localData: localData,
                conflictTitle: entry.title,
                remoteID: remote.id,
                remoteRev: remote.headRevisionId,
                remoteModified: remote.modifiedTime,
                remoteData: remoteData,
                remoteDoc: remoteDoc,
                remoteHash: remoteHash
            )
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
        onEvent?(.documentPulled(docID: entry.docID, url: targetURL))
    }

    private func saveNewRemoteDocument(docID: UUID,
                                       remote: RemoteFile,
                                       remoteData: Data,
                                       remoteDoc: MarginsDocument,
                                       remoteHash: String) throws {
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

    private func applyConflict(entry: SyncEntry,
                               localURL: URL,
                               localData: Data,
                               conflictTitle: String,
                               remoteID: String?,
                               remoteRev: String?,
                               remoteModified: Date?,
                               remoteData: Data,
                               remoteDoc: MarginsDocument,
                               remoteHash: String) throws {
        let conflictURL = try writeConflictCopy(localData: localData, title: conflictTitle)
        try remoteData.write(to: localURL, options: .atomic)
        Self.regenerateMarkdown(for: remoteDoc, at: localURL)

        var updated = entry
        if let remoteID { updated.driveFileId = remoteID }
        updated.lastSyncedRevision = remoteRev
        updated.lastSyncedContentHash = remoteHash
        updated.title = remoteDoc.title
        updated.modifiedAt = remoteModified ?? now()
        updated.state = .conflict
        updated.conflictFilename = conflictURL.lastPathComponent
        index.setEntry(updated)
        onEvent?(.conflictCreated(docID: entry.docID, localURL: localURL, conflictURL: conflictURL))
        onEvent?(.documentPulled(docID: entry.docID, url: localURL))
    }

    // MARK: - Push

    func pushEntry(_ entry: SyncEntry, folderID: String) async throws {
        let localURL = entry.localURL(in: documentsFolder)
        guard let localData = try? Data(contentsOf: localURL),
              let localDoc = try? MarginsDocument.decode(localData) else { return }
        let localHash = Self.sha256Hex(localData)

        if try await resolveRemoteConflictBeforePush(entry: entry, localURL: localURL, localData: localData, localDoc: localDoc, localHash: localHash) {
            return
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

    /// Returns `true` if a remote conflict was detected and resolved locally (skipping upload).
    private func resolveRemoteConflictBeforePush(entry: SyncEntry,
                                                 localURL: URL,
                                                 localData: Data,
                                                 localDoc: MarginsDocument,
                                                 localHash: String) async throws -> Bool {
        // V1 conflict check: before uploading over an existing Drive file, verify headRevisionId.
        guard let fileID = entry.driveFileId,
              let expectedRev = entry.lastSyncedRevision,
              let remoteMeta = try await backend.getMetadata(fileID: fileID),
              !remoteMeta.trashed,
              let remoteRev = remoteMeta.headRevisionId,
              remoteRev != expectedRev else {
            return false
        }

        let remoteData = try await backend.download(fileID: fileID)
        let remoteHash = Self.sha256Hex(remoteData)
        guard remoteHash != localHash else { return false }

        let remoteDoc = try MarginsDocument.decode(remoteData)
        try applyConflict(
            entry: entry,
            localURL: localURL,
            localData: localData,
            conflictTitle: localDoc.title,
            remoteID: nil,
            remoteRev: remoteRev,
            remoteModified: remoteMeta.modifiedTime,
            remoteData: remoteData,
            remoteDoc: remoteDoc,
            remoteHash: remoteHash
        )
        return true
    }
}

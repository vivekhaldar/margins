import Foundation

public enum DocumentSyncState: String, Codable, Equatable, Sendable {
    case synced
    case pendingUpload
    case downloading
    case cloudOnly
    case conflict
}

public struct SyncEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { docID }
    public var docID: UUID
    public var driveFileId: String?
    public var lastSyncedRevision: String?
    public var lastSyncedContentHash: String?
    public var filename: String
    public var title: String
    public var modifiedAt: Date
    public var state: DocumentSyncState
    public var conflictFilename: String?

    public init(docID: UUID,
                driveFileId: String? = nil,
                lastSyncedRevision: String? = nil,
                lastSyncedContentHash: String? = nil,
                filename: String,
                title: String,
                modifiedAt: Date = Date(),
                state: DocumentSyncState = .pendingUpload,
                conflictFilename: String? = nil) {
        self.docID = docID
        self.driveFileId = driveFileId
        self.lastSyncedRevision = lastSyncedRevision
        self.lastSyncedContentHash = lastSyncedContentHash
        self.filename = filename
        self.title = title
        self.modifiedAt = modifiedAt
        self.state = state
        self.conflictFilename = conflictFilename
    }

    public func localURL(in documentsFolder: URL) -> URL {
        documentsFolder.appendingPathComponent(filename)
    }
}

/// Persistent index (`sync-index.json`) mapping `MarginsDocument.id` ↔ Drive file ID,
/// revision, content hash, and local filename.
public struct SyncIndex: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int = SyncIndex.currentFormat
    public var folderID: String?
    public var startPageToken: String?
    public var lastSyncedAt: Date?
    public var entries: [String: SyncEntry] = [:]

    public init(folderID: String? = nil, startPageToken: String? = nil,
                lastSyncedAt: Date? = nil, entries: [String: SyncEntry] = [:]) {
        self.folderID = folderID
        self.startPageToken = startPageToken
        self.lastSyncedAt = lastSyncedAt
        self.entries = entries
    }

    public func entry(for docID: UUID) -> SyncEntry? {
        entries[docID.uuidString]
    }

    public mutating func setEntry(_ entry: SyncEntry) {
        entries[entry.docID.uuidString] = entry
    }

    public mutating func removeEntry(for docID: UUID) {
        entries.removeValue(forKey: docID.uuidString)
    }

    public func entry(forDriveFileId fileId: String) -> SyncEntry? {
        entries.values.first { $0.driveFileId == fileId }
    }

    public func entry(forFilename filename: String) -> SyncEntry? {
        entries.values.first { $0.filename == filename }
    }

    public var sortedByRecency: [SyncEntry] {
        entries.values.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public var conflictCount: Int {
        entries.values.filter { $0.state == .conflict }.count
    }

    public var pendingUploadCount: Int {
        entries.values.filter { $0.state == .pendingUpload }.count
    }

    public static func load(from url: URL) -> SyncIndex {
        guard let data = try? Data(contentsOf: url) else { return SyncIndex() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(SyncIndex.self, from: data)) ?? SyncIndex()
    }

    public func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

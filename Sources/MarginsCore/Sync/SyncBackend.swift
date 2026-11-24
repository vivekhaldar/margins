import Foundation

public struct RemoteFile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var docID: UUID?
    public var headRevisionId: String?
    public var modifiedTime: Date?
    public var trashed: Bool
    public var size: Int64?

    public init(id: String, name: String, docID: UUID? = nil, headRevisionId: String? = nil,
                modifiedTime: Date? = nil, trashed: Bool = false, size: Int64? = nil) {
        self.id = id
        self.name = name
        self.docID = docID
        self.headRevisionId = headRevisionId
        self.modifiedTime = modifiedTime
        self.trashed = trashed
        self.size = size
    }
}

public struct RemoteChange: Equatable, Sendable {
    public var fileId: String
    public var removed: Bool
    public var file: RemoteFile?

    public init(fileId: String, removed: Bool, file: RemoteFile? = nil) {
        self.fileId = fileId
        self.removed = removed
        self.file = file
    }
}

public struct ChangesPage: Equatable, Sendable {
    public var changes: [RemoteChange]
    public var newStartPageToken: String

    public init(changes: [RemoteChange], newStartPageToken: String) {
        self.changes = changes
        self.newStartPageToken = newStartPageToken
    }
}

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case notAuthenticated
    case missingConfiguration(String)
    case offline(String)
    case httpError(Int, String)
    case invalidResponse(String)
    case conflict(remoteRevision: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to Google Drive."
        case .missingConfiguration(let msg):
            return msg
        case .offline(let msg):
            return "Offline: \(msg)"
        case .httpError(let code, let msg):
            return "Sync HTTP \(code): \(msg)"
        case .invalidResponse(let msg):
            return "Invalid sync response: \(msg)"
        case .conflict(let rev):
            return "Remote document changed (revision \(rev))."
        case .cancelled:
            return "Sync cancelled."
        }
    }

    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

/// Pluggable HTTP transport so OAuth and Drive clients can be unit-tested deterministically without network access.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse("Non-HTTP response")
            }
            return (data, http)
        } catch let err as URLError {
            switch err.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
                throw SyncError.offline(err.localizedDescription)
            case .cancelled:
                throw SyncError.cancelled
            default:
                throw SyncError.offline(err.localizedDescription)
            }
        }
    }
}

/// Pluggable cloud sync backend. Google Drive is the first implementation;
/// iCloud, S3/R2, or WebDAV can implement this protocol without changing the editor or engine.
public protocol SyncBackend: Sendable {
    func ensureRootFolder() async throws -> String
    func listFiles(folderID: String) async throws -> [RemoteFile]
    func getStartPageToken() async throws -> String
    func listChanges(pageToken: String, folderID: String) async throws -> ChangesPage
    func getMetadata(fileID: String) async throws -> RemoteFile?
    func download(fileID: String) async throws -> Data
    func upload(data: Data, name: String, docID: UUID, folderID: String, existingFileID: String?) async throws -> RemoteFile
    func rename(fileID: String, newName: String) async throws -> RemoteFile
    func delete(fileID: String) async throws
}

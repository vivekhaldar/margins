import Foundation

/// Google Drive REST v3 implementation of `SyncBackend` using the narrow `drive.file` scope
/// and a visible `Margins` folder tagged with `appProperties`.
public final class GoogleDriveBackend: SyncBackend, @unchecked Sendable {
    public static let apiBase = "https://www.googleapis.com/drive/v3"
    public static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    public static let rootFolderName = "Margins"
    public static let rootPropertyKey = "marginsRoot"
    public static let docIDPropertyKey = "marginsDocId"

    private let tokenProvider: @Sendable (Bool) async throws -> String
    private let http: HTTPClient

    public init(oauth: GoogleOAuthClient, http: HTTPClient = URLSessionHTTPClient()) {
        self.tokenProvider = { forceRefresh in
            try await oauth.validAccessToken(forceRefresh: forceRefresh)
        }
        self.http = http
    }

    public init(tokenProvider: @escaping @Sendable (Bool) async throws -> String,
                http: HTTPClient = URLSessionHTTPClient()) {
        self.tokenProvider = tokenProvider
        self.http = http
    }

    public func ensureRootFolder() async throws -> String {
        let query = "mimeType = 'application/vnd.google-apps.folder' and trashed = false and appProperties has { key='\(Self.rootPropertyKey)' and value='true' }"
        var comps = URLComponents(string: "\(Self.apiBase)/files")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        let (data, _) = try await authorizedRequest(url: comps.url!, method: "GET")
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = obj["files"] as? [[String: Any]],
           let firstID = files.first?["id"] as? String {
            return firstID
        }

        let metadata: [String: Any] = [
            "name": Self.rootFolderName,
            "mimeType": "application/vnd.google-apps.folder",
            "appProperties": [Self.rootPropertyKey: "true"],
        ]
        let body = try JSONSerialization.data(withJSONObject: metadata)
        var createComps = URLComponents(string: "\(Self.apiBase)/files")!
        createComps.queryItems = [URLQueryItem(name: "fields", value: "id,name")]
        let (createdData, _) = try await authorizedRequest(
            url: createComps.url!,
            method: "POST",
            contentType: "application/json",
            body: body
        )
        guard let created = try? JSONSerialization.jsonObject(with: createdData) as? [String: Any],
              let id = created["id"] as? String else {
            throw SyncError.invalidResponse("Missing folder id in Drive create response")
        }
        return id
    }

    public func listFiles(folderID: String) async throws -> [RemoteFile] {
        var result: [RemoteFile] = []
        var pageToken: String? = nil
        let escapedFolder = folderID.replacingOccurrences(of: "'", with: "\\'")

        repeat {
            var comps = URLComponents(string: "\(Self.apiBase)/files")!
            var items = [
                URLQueryItem(name: "q", value: "'\(escapedFolder)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,headRevisionId,modifiedTime,trashed,size,appProperties)"),
                URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items

            let (data, _) = try await authorizedRequest(url: comps.url!, method: "GET")
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.invalidResponse("Invalid JSON in files.list")
            }
            if let files = obj["files"] as? [[String: Any]] {
                for raw in files {
                    if let file = Self.parseRemoteFile(raw) {
                        result.append(file)
                    }
                }
            }
            pageToken = obj["nextPageToken"] as? String
        } while pageToken != nil && !pageToken!.isEmpty

        return result
    }

    public func getStartPageToken() async throws -> String {
        let url = URL(string: "\(Self.apiBase)/changes/startPageToken")!
        let (data, _) = try await authorizedRequest(url: url, method: "GET")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["startPageToken"] as? String else {
            throw SyncError.invalidResponse("Missing startPageToken")
        }
        return token
    }

    public func listChanges(pageToken: String, folderID: String) async throws -> ChangesPage {
        var allChanges: [RemoteChange] = []
        var cursor: String? = pageToken
        var newStartToken = pageToken

        while let token = cursor, !token.isEmpty {
            var comps = URLComponents(string: "\(Self.apiBase)/changes")!
            comps.queryItems = [
                URLQueryItem(name: "pageToken", value: token),
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,headRevisionId,modifiedTime,trashed,size,parents,appProperties))"),
            ]
            let (data, _) = try await authorizedRequest(url: comps.url!, method: "GET")
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.invalidResponse("Invalid JSON in changes.list")
            }
            if let changes = obj["changes"] as? [[String: Any]] {
                for raw in changes {
                    guard let fileId = raw["fileId"] as? String else { continue }
                    let removed = (raw["removed"] as? Bool) ?? false
                    let rawFile = raw["file"] as? [String: Any]
                    let parsed = rawFile.flatMap(Self.parseRemoteFile)
                    let parents = rawFile?["parents"] as? [String] ?? []
                    let relevant = removed || parents.contains(folderID) || parsed?.docID != nil
                    if relevant {
                        allChanges.append(RemoteChange(fileId: fileId, removed: removed || (parsed?.trashed ?? false), file: parsed))
                    }
                }
            }
            if let next = obj["nextPageToken"] as? String, !next.isEmpty {
                cursor = next
            } else {
                cursor = nil
                if let start = obj["newStartPageToken"] as? String, !start.isEmpty {
                    newStartToken = start
                }
            }
        }

        return ChangesPage(changes: allChanges, newStartPageToken: newStartToken)
    }

    public func getMetadata(fileID: String) async throws -> RemoteFile? {
        var comps = URLComponents(string: "\(Self.apiBase)/files/\(fileID)")!
        comps.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,headRevisionId,modifiedTime,trashed,size,appProperties"),
        ]
        do {
            let (data, _) = try await authorizedRequest(url: comps.url!, method: "GET")
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.invalidResponse("Invalid JSON in files.get")
            }
            return Self.parseRemoteFile(obj)
        } catch SyncError.httpError(404, _) {
            return nil
        }
    }

    public func download(fileID: String) async throws -> Data {
        var comps = URLComponents(string: "\(Self.apiBase)/files/\(fileID)")!
        comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
        let (data, _) = try await authorizedRequest(url: comps.url!, method: "GET")
        return data
    }

    public func upload(data: Data, name: String, docID: UUID, folderID: String, existingFileID: String?) async throws -> RemoteFile {
        var metadata: [String: Any] = [
            "name": name,
            "appProperties": [Self.docIDPropertyKey: docID.uuidString],
        ]
        let method: String
        let baseURL: String
        if let existingFileID {
            method = "PATCH"
            baseURL = "\(Self.uploadBase)/files/\(existingFileID)"
        } else {
            method = "POST"
            baseURL = "\(Self.uploadBase)/files"
            metadata["parents"] = [folderID]
        }

        var comps = URLComponents(string: baseURL)!
        comps.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,name,headRevisionId,modifiedTime,trashed,size,appProperties"),
        ]

        let boundary = "margins-sync-\(UUID().uuidString)"
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataJSON)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (respData, _) = try await authorizedRequest(
            url: comps.url!,
            method: method,
            contentType: "multipart/related; boundary=\(boundary)",
            body: body
        )
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let file = Self.parseRemoteFile(obj) else {
            throw SyncError.invalidResponse("Invalid JSON in files.upload")
        }
        return file
    }

    public func rename(fileID: String, newName: String) async throws -> RemoteFile {
        var comps = URLComponents(string: "\(Self.apiBase)/files/\(fileID)")!
        comps.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,headRevisionId,modifiedTime,trashed,size,appProperties"),
        ]
        let body = try JSONSerialization.data(withJSONObject: ["name": newName])
        let (respData, _) = try await authorizedRequest(
            url: comps.url!,
            method: "PATCH",
            contentType: "application/json",
            body: body
        )
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let file = Self.parseRemoteFile(obj) else {
            throw SyncError.invalidResponse("Invalid JSON in files.rename")
        }
        return file
    }

    public func delete(fileID: String) async throws {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)")!
        _ = try await authorizedRequest(url: url, method: "DELETE")
    }

    // MARK: - Helpers

    private func authorizedRequest(url: URL, method: String, contentType: String? = nil, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let token = try await tokenProvider(false)
        let (data, resp) = try await perform(url: url, method: method, token: token, contentType: contentType, body: body)
        if resp.statusCode == 401 {
            let refreshed = try await tokenProvider(true)
            let (retryData, retryResp) = try await perform(url: url, method: method, token: refreshed, contentType: contentType, body: body)
            try checkStatus(retryResp, retryData)
            return (retryData, retryResp)
        }
        try checkStatus(resp, data)
        return (data, resp)
    }

    private func perform(url: URL, method: String, token: String, contentType: String?, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        req.httpBody = body
        req.timeoutInterval = 60
        return try await http.data(for: req)
    }

    private func checkStatus(_ resp: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(resp.statusCode) else {
            let msg = String(decoding: data.prefix(400), as: UTF8.self)
            throw SyncError.httpError(resp.statusCode, msg)
        }
    }

    public static func parseRemoteFile(_ raw: [String: Any]) -> RemoteFile? {
        guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
        let props = raw["appProperties"] as? [String: Any]
        let docID = (props?[docIDPropertyKey] as? String).flatMap(UUID.init(uuidString:))
        let headRev = raw["headRevisionId"] as? String
        let trashed = (raw["trashed"] as? Bool) ?? false
        let size: Int64?
        if let s = raw["size"] as? String { size = Int64(s) }
        else if let n = raw["size"] as? Int64 { size = n }
        else if let n = raw["size"] as? Int { size = Int64(n) }
        else { size = nil }

        let modifiedTime: Date?
        if let rawDate = raw["modifiedTime"] as? String {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            modifiedTime = f1.date(from: rawDate) ?? f2.date(from: rawDate)
        } else {
            modifiedTime = nil
        }
        return RemoteFile(
            id: id,
            name: name,
            docID: docID,
            headRevisionId: headRev,
            modifiedTime: modifiedTime,
            trashed: trashed,
            size: size
        )
    }
}

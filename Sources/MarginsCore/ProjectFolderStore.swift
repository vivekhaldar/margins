import Foundation

/// Per-machine mapping from `MarginsDocument.id` to local project folder path.
/// Keeps machine-specific repository paths out of synced `.margins` files while
/// falling back to the legacy `doc.projectFolder` field for migration.
public final class ProjectFolderStore: @unchecked Sendable {
    public static let shared = ProjectFolderStore()
    public static let didChangeNotification = Notification.Name("ProjectFolderStoreDidChange")
    public static let maxRecentCount = 10

    private struct Payload: Codable {
        var version: Int
        var documents: [String: String]
        var recent: [String]

        enum CodingKeys: String, CodingKey { case version, documents, recent }

        init(version: Int = 1, documents: [String: String] = [:], recent: [String] = []) {
            self.version = version
            self.documents = documents
            self.recent = recent
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            documents = try container.decode([String: String].self, forKey: .documents)
            recent = try container.decodeIfPresent([String].self, forKey: .recent) ?? []
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var mappings: [String: String]
    private var recent: [String]

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margins", isDirectory: true)
        return support.appendingPathComponent("project-folders.json")
    }

    public init(fileURL: URL = ProjectFolderStore.defaultURL) {
        self.fileURL = fileURL
        let loaded = Self.load(from: fileURL)
        self.mappings = loaded.documents
        self.recent = loaded.recent
    }

    public func folder(for docID: UUID, fallbackDocumentFolder: String? = nil) -> String? {
        lock.lock()
        let local = mappings[docID.uuidString]
        lock.unlock()
        if let local { return local.isEmpty ? nil : local }
        if let fallbackDocumentFolder, !fallbackDocumentFolder.isEmpty {
            return fallbackDocumentFolder
        }
        return nil
    }

    public func setFolder(_ path: String?, for docID: UUID) {
        let standardized = path.flatMap(Self.normalize)
        lock.lock()
        if let standardized {
            mappings[docID.uuidString] = standardized
            recordRecentLocked(standardized)
        } else {
            mappings.removeValue(forKey: docID.uuidString)
        }
        let snapshot = Payload(documents: mappings, recent: recent)
        lock.unlock()
        save(snapshot)
    }

    /// Migrates a legacy `doc.projectFolder` into the per-machine store if no local mapping exists yet.
    public func migrateIfNeeded(docID: UUID, legacyFolder: String?) {
        guard let standardized = legacyFolder.flatMap(Self.normalize) else { return }
        lock.lock()
        let exists = mappings[docID.uuidString] != nil
        if !exists {
            mappings[docID.uuidString] = standardized
            recordRecentLocked(standardized)
        }
        let snapshot = Payload(documents: mappings, recent: recent)
        lock.unlock()
        if !exists { save(snapshot) }
    }

    public func recentFolders(limit: Int = ProjectFolderStore.maxRecentCount) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let copy = Array(recent.prefix(limit))
        lock.unlock()
        return copy
    }

    /// Filters out deleted directories in memory so they are lazily pruned on the next save.
    public func existingRecentFolders(
        limit: Int = ProjectFolderStore.maxRecentCount,
        isDirectory: (String) -> Bool = ProjectFolderStore.directoryExists
    ) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        recent = recent.filter(isDirectory)
        let copy = Array(recent.prefix(limit))
        lock.unlock()
        return copy
    }

    public func removeRecentFolder(_ path: String) {
        guard let standardized = Self.normalize(path) else { return }
        lock.lock()
        let before = recent.count
        recent.removeAll { $0 == standardized }
        let changed = recent.count != before
        let snapshot = Payload(documents: mappings, recent: recent)
        lock.unlock()
        if changed { save(snapshot) }
    }

    public func clearRecentFolders() {
        lock.lock()
        let changed = !recent.isEmpty
        recent.removeAll()
        let snapshot = Payload(documents: mappings, recent: recent)
        lock.unlock()
        if changed { save(snapshot) }
    }

    public func allMappings() -> [UUID: String] {
        lock.lock()
        let copy = mappings
        lock.unlock()
        var out: [UUID: String] = [:]
        for (k, v) in copy {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }

    /// Returns the folder's `lastPathComponent`, appending a tilde-abbreviated path when multiple entries share the same name.
    public static func displayLabel(for url: URL, among urls: [URL]) -> String {
        let name = url.lastPathComponent
        let hasDuplicate = urls.filter { $0.lastPathComponent == name }.count > 1
        guard hasDuplicate else { return name }
        let abbreviated = (url.path as NSString).abbreviatingWithTildeInPath
        return "\(name) — \(abbreviated)"
    }

    private func recordRecentLocked(_ standardizedPath: String) {
        recent.removeAll { $0 == standardizedPath }
        recent.insert(standardizedPath, at: 0)
        if recent.count > Self.maxRecentCount {
            recent = Array(recent.prefix(Self.maxRecentCount))
        }
    }

    private static func normalize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    public static func directoryExists(atPath path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in paths {
            guard let normalized = normalize(raw), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count >= maxRecentCount { break }
        }
        return result
    }

    private static func load(from url: URL) -> Payload {
        guard let data = try? Data(contentsOf: url) else { return Payload() }
        if let structured = try? JSONDecoder().decode(Payload.self, from: data) {
            return Payload(
                version: structured.version,
                documents: structured.documents,
                recent: deduplicated(structured.recent)
            )
        }
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            let seeded = deduplicated(legacy.values.sorted())
            return Payload(documents: legacy, recent: seeded)
        }
        return Payload()
    }

    private func save(_ snapshot: Payload) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

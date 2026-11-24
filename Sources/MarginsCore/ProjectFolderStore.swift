import Foundation

/// Per-machine mapping from `MarginsDocument.id` to local project folder path.
/// Keeps machine-specific repository paths out of synced `.margins` files while
/// falling back to the legacy `doc.projectFolder` field for migration.
public final class ProjectFolderStore: @unchecked Sendable {
    public static let shared = ProjectFolderStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var mappings: [String: String]

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margins", isDirectory: true)
        return support.appendingPathComponent("project-folders.json")
    }

    public init(fileURL: URL = ProjectFolderStore.defaultURL) {
        self.fileURL = fileURL
        self.mappings = Self.load(from: fileURL)
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
        let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if let normalized, !normalized.isEmpty {
            mappings[docID.uuidString] = URL(fileURLWithPath: normalized).standardizedFileURL.path
        } else {
            mappings.removeValue(forKey: docID.uuidString)
        }
        let snapshot = mappings
        lock.unlock()
        save(snapshot)
    }

    /// Migrates a legacy `doc.projectFolder` into the per-machine store if no local mapping exists yet.
    public func migrateIfNeeded(docID: UUID, legacyFolder: String?) {
        guard let legacyFolder, !legacyFolder.isEmpty else { return }
        lock.lock()
        let exists = mappings[docID.uuidString] != nil
        if !exists {
            mappings[docID.uuidString] = URL(fileURLWithPath: legacyFolder).standardizedFileURL.path
        }
        let snapshot = mappings
        lock.unlock()
        if !exists { save(snapshot) }
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

    private static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ snapshot: [String: String]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

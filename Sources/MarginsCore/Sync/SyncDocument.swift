import Foundation

/// The exact bytes to hash, store and transfer, together with their decoded document.
public struct SyncDocument {
    public let data: Data
    public let document: MarginsDocument

    private struct Contents: Decodable {
        let document: MarginsDocument
        let hasID: Bool

        static func decode(_ data: Data) throws -> Contents {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Contents.self, from: data)
        }

        init(from decoder: Decoder) throws {
            document = try MarginsDocument(from: decoder)
            let fields = try decoder.container(keyedBy: MarginsDocument.CodingKeys.self)
            hasID = try fields.decodeIfPresent(UUID.self, forKey: .id) != nil
        }
    }

    init(_ original: Data, legacyID: () -> UUID?) throws {
        let contents = try Contents.decode(original)
        var doc = contents.document
        if contents.hasID {
            data = original
        } else {
            doc.id = legacyID() ?? doc.id
            // Change only the top-level identity. Preserve unknown fields and the
            // original version history, even when older versions also lack IDs.
            guard var fields = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SyncError.invalidResponse("Expected a Margins document object.")
            }
            fields["id"] = doc.id.uuidString
            data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
        document = doc
    }

    /// Persist a legacy ID before any caller can index, open or upload it. Re-read
    /// under coordination so overlapping scans and opens adopt the same migration.
    public static func load(at url: URL, index: SyncIndex) throws -> SyncDocument {
        let bytes = try Data(contentsOf: url)
        let contents = try Contents.decode(bytes)
        if contents.hasID { return SyncDocument(data: bytes, document: contents.document) }

        var error: NSError?
        var result: Result<SyncDocument, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { target in
            result = Result {
                let bytes = try Data(contentsOf: target)
                let current = try SyncDocument(bytes) {
                    index.legacyID(filename: target.lastPathComponent, contentHash: SyncEngine.sha256Hex(bytes))
                }
                if current.data != bytes { try current.data.write(to: target, options: .atomic) }
                return current
            }
        }
        if let result { return try result.get() }
        throw error ?? CocoaError(.fileWriteUnknown) as NSError
    }

    private init(data: Data, document: MarginsDocument) {
        self.data = data
        self.document = document
    }
}

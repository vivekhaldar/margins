import Foundation

/// On-disk `.margins` document: the HTML (including any pending tracked changes),
/// the instruction log, and the full version history.
public struct MarginsDocument: Codable, Equatable, Sendable {
    public static let fileExtension = "margins"
    public static let currentFormat = 1

    public var format: Int = MarginsDocument.currentFormat
    public var html: String
    public var intents: [Intent]
    public var versions: [Version]
    public var nextStep: Int

    public init(html: String = "", intents: [Intent] = [], versions: [Version] = [], nextStep: Int = 1) {
        self.html = html
        self.intents = intents
        self.versions = versions
        self.nextStep = nextStep
    }

    /// Title = text of the first <h1>, else "Untitled".
    public var title: String {
        guard let r = html.range(of: "<h1[^>]*>(.*?)</h1>", options: [.regularExpression, .caseInsensitive]) else {
            return "Untitled"
        }
        let inner = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    @discardableResult
    public mutating func snapshot(html: String, slug: String, author: Version.Author, detail: String = "",
                                  at date: Date = Date()) -> Version {
        self.html = html
        let v = Version(number: (versions.last?.number ?? 0) + 1, html: html, slug: slug,
                        author: author, detail: detail, createdAt: date)
        versions.append(v)
        return v
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> MarginsDocument {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MarginsDocument.self, from: data)
    }
}

public struct Intent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case instruction, edit }
    public enum Status: String, Codable, Sendable { case working, pending, reviewed, failed, done }

    public struct Refinement: Codable, Equatable, Sendable {
        public var text: String
        public var at: Date
        public init(text: String, at: Date = Date()) { self.text = text; self.at = at }
    }

    public var id: UUID
    public var kind: Kind
    public var step: Int
    public var text: String
    public var createdAt: Date
    public var status: Status
    public var summary: String
    public var notes: [String]
    public var refinements: [Refinement]
    public var provider: String
    public var error: String?

    public init(id: UUID = UUID(), kind: Kind = .instruction, step: Int, text: String, createdAt: Date = Date(),
                status: Status = .working, summary: String = "", notes: [String] = [],
                refinements: [Refinement] = [], provider: String = "", error: String? = nil) {
        self.id = id
        self.kind = kind
        self.step = step
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.summary = summary
        self.notes = notes
        self.refinements = refinements
        self.provider = provider
        self.error = error
    }
}

public struct Version: Codable, Equatable, Identifiable, Sendable {
    public enum Author: String, Codable, Sendable { case agent, you, review }
    public var id: UUID = UUID()
    public var number: Int
    public var html: String
    public var slug: String
    public var author: Author
    public var detail: String
    public var createdAt: Date
}

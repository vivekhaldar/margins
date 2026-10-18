import Foundation

/// On-disk `.margins` document: the HTML (including any pending tracked changes),
/// the instruction log, and the full version history.
public struct MarginsDocument: Codable, Equatable, Sendable {
    public static let fileExtension = "margins"
    public static let currentFormat = 2

    public var format: Int = MarginsDocument.currentFormat
    /// Stable identity; keys the agent's per-document workspace folder.
    public var id = UUID()
    public var html: String
    public var intents: [Intent]
    public var versions: [Version]
    public var nextStep: Int
    /// Images referenced from `html` / version snapshots, keyed by content hash.
    public var assets: [String: Asset] = [:]
    /// The author's project (e.g. a code repo) the agent works in. Nil = a private per-document workspace.
    public var projectFolder: String?
    public var annotations = DocumentAnnotations()
    public var annotationRuns: [AnnotationRun] = []

    public init(html: String = "", intents: [Intent] = [], versions: [Version] = [], nextStep: Int = 1) {
        self.html = html
        self.intents = intents
        self.versions = versions
        self.nextStep = nextStep
    }

    enum CodingKeys: String, CodingKey { case format, id, html, intents, versions, nextStep, assets, projectFolder, annotations, annotationRuns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? MarginsDocument.currentFormat
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        html = try c.decode(String.self, forKey: .html)
        intents = try c.decode([Intent].self, forKey: .intents)
        versions = try c.decode([Version].self, forKey: .versions)
        nextStep = try c.decode(Int.self, forKey: .nextStep)
        assets = try c.decodeIfPresent([String: Asset].self, forKey: .assets) ?? [:]
        projectFolder = try c.decodeIfPresent(String.self, forKey: .projectFolder)
        annotations = try c.decodeIfPresent(DocumentAnnotations.self, forKey: .annotations) ?? DocumentAnnotations()
        annotationRuns = try c.decodeIfPresent([AnnotationRun].self, forKey: .annotationRuns) ?? []
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
                                  annotations: DocumentAnnotations? = nil,
                                  at date: Date = Date()) -> Version {
        self.html = html
        if let annotations { self.annotations = annotations }
        let v = Version(number: (versions.last?.number ?? 0) + 1, html: html, slug: slug,
                        author: author, detail: detail, createdAt: date,
                        annotations: self.annotations, annotationRuns: annotationRuns)
        versions.append(v)
        return v
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        var document = self
        document.format = max(document.format, Self.currentFormat)
        return try enc.encode(document)
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
    /// Tool calls the agent made while working on this instruction (nil for one-shot runs).
    public var steps: [AgentStep]?
    /// Inline discussion: messages in one thread share an id and are anchored to `quote` in block `anchor`.
    public var thread: UUID?
    public var quote: String?
    public var anchor: String?
    /// Blocks the selection spanned when the thread started.
    public var focus: [String]?
    /// The agent's answer in an inline discussion.
    public var reply: String?
    /// Project files the agent created, changed or deleted while working on this (relative paths).
    public var files: [String]?

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
    public var annotations: DocumentAnnotations = DocumentAnnotations()
    public var annotationRuns: [AnnotationRun] = []

    enum CodingKeys: String, CodingKey { case id, number, html, slug, author, detail, createdAt, annotations, annotationRuns }

    public init(id: UUID = UUID(), number: Int, html: String, slug: String, author: Author, detail: String,
                createdAt: Date, annotations: DocumentAnnotations = DocumentAnnotations(), annotationRuns: [AnnotationRun] = []) {
        self.id = id; self.number = number; self.html = html; self.slug = slug
        self.author = author; self.detail = detail; self.createdAt = createdAt
        self.annotations = annotations; self.annotationRuns = annotationRuns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try c.decode(Int.self, forKey: .number)
        html = try c.decode(String.self, forKey: .html)
        slug = try c.decode(String.self, forKey: .slug)
        author = try c.decode(Author.self, forKey: .author)
        detail = try c.decode(String.self, forKey: .detail)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        annotations = try c.decodeIfPresent(DocumentAnnotations.self, forKey: .annotations) ?? DocumentAnnotations()
        annotationRuns = try c.decodeIfPresent([AnnotationRun].self, forKey: .annotationRuns) ?? []
    }
}

import Foundation

/// Lossless JSON used by the editor's versioned range engine. Keeping unknown fields is
/// deliberate: a newer editor may add anchor diagnostics or tracked-change information.
public enum AnnotationValue: Codable, Equatable, Sendable {
    case object([String: AnnotationValue]), array([AnnotationValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([AnnotationValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: AnnotationValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
}

/// Range provenance and local comment threads, serialized alongside the exact HTML
/// revision they describe. Coordinates and transformations belong to the editor.
public struct DocumentAnnotations: Codable, Equatable, Sendable {
    public var fields: [String: AnnotationValue]
    public init(fields: [String: AnnotationValue] = [:]) { self.fields = fields }
    public var revision: Int {
        guard case .number(let n) = fields["revision"] else { return 0 }
        return Int(n)
    }
    public init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: AnnotationValue].self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }
}

/// A stable invocation identity, separate from a step number and from provider names.
/// Each refinement is a distinct run linked to the original instruction and prior run.
public struct AnnotationRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var intentId: UUID
    public var step: Int
    public var provider: String
    public var model: String
    public var createdAt: Date
    public var instruction: String
    public var refinement: String?
    public var parentRunId: UUID?
    public var summary: String
    public var notes: [String]
    public var steps: [AgentStep]
    public var status: String
    public var refinements: [Intent.Refinement]
    public var files: [String]

    enum CodingKeys: String, CodingKey {
        case id, intentId, step, provider, model, createdAt, instruction, refinement, parentRunId, summary, notes, steps, status, refinements, files
    }

    public init(id: UUID = UUID(), intentId: UUID, step: Int, provider: String, model: String,
                createdAt: Date = Date(), instruction: String, refinement: String? = nil,
                parentRunId: UUID? = nil, summary: String = "", notes: [String] = [],
                steps: [AgentStep] = [], status: String = "working", refinements: [Intent.Refinement] = [], files: [String] = []) {
        self.id = id; self.intentId = intentId; self.step = step
        self.provider = provider; self.model = model; self.createdAt = createdAt
        self.instruction = instruction; self.refinement = refinement; self.parentRunId = parentRunId
        self.summary = summary; self.notes = notes; self.steps = steps; self.status = status
        self.refinements = refinements; self.files = files
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        intentId = try c.decode(UUID.self, forKey: .intentId)
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        refinement = try c.decodeIfPresent(String.self, forKey: .refinement)
        parentRunId = try c.decodeIfPresent(UUID.self, forKey: .parentRunId)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        steps = try c.decodeIfPresent([AgentStep].self, forKey: .steps) ?? []
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "done"
        refinements = try c.decodeIfPresent([Intent.Refinement].self, forKey: .refinements) ?? []
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
    }
}

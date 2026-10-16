import Foundation

/// A structured, minimal set of block-level edits returned by a model.
/// Models never "reply" in Margins — they return an EditPlan that the editor
/// renders as tracked changes.
public struct EditPlan: Codable, Equatable, Sendable {
    public var slug: String
    public var summary: String
    public var notes: [String]
    public var edits: [EditOp]
    /// An answer for the author, used only in inline discussions of a selection. Usually empty.
    public var reply: String

    public init(slug: String = "", summary: String = "", notes: [String] = [], edits: [EditOp], reply: String = "") {
        self.slug = slug
        self.summary = summary
        self.notes = notes
        self.edits = edits
        self.reply = reply
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        notes = (try? c.decode([String].self, forKey: .notes)) ?? []
        edits = try c.decode([EditOp].self, forKey: .edits)
        reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
    }
}

public struct EditOp: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable {
        case replace, insertAfter, delete
    }
    public var op: Op
    /// Target block id. For `insertAfter`, "^" means "at the start of the document".
    public var blockId: String
    public var html: String

    public init(op: Op, blockId: String, html: String = "") {
        self.op = op
        self.blockId = blockId
        self.html = html
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(Op.self, forKey: .op)
        blockId = try c.decode(String.self, forKey: .blockId)
        html = (try? c.decode(String.self, forKey: .html)) ?? ""
    }
}

public enum EditPlanSchema {
    /// Strict JSON Schema (all properties required, no extras) — accepted by
    /// OpenAI structured outputs, `codex exec --output-schema` and `claude --json-schema`.
    public static let json: String = """
    {"type":"object","additionalProperties":false,"required":["slug","summary","notes","edits","reply"],
     "properties":{
      "slug":{"type":"string","description":"<=6 word lowercase label for this change, used in version history"},
      "summary":{"type":"string","description":"One sentence describing what changed"},
      "notes":{"type":"array","items":{"type":"string"},"description":"0-3 short assumptions or questions for the author"},
      "edits":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["op","blockId","html"],
        "properties":{
          "op":{"type":"string","enum":["replace","insertAfter","delete"]},
          "blockId":{"type":"string"},
          "html":{"type":"string"}}}},
      "reply":{"type":"string","description":"Answer to the author when they are discussing a selection with you; otherwise empty"}}}
    """

    public static var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}

public enum EditPlanParser {
    public enum ParseError: LocalizedError {
        case noJSON(String)
        case invalid(String, underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .noJSON(let s): return "Model did not return JSON: \(s.prefix(200))"
            case .invalid(let s, let e): return "Could not decode edit plan (\(e.localizedDescription)): \(s.prefix(200))"
            }
        }
    }

    /// Tolerant parse: accepts bare JSON, fenced ```json blocks, or JSON embedded in prose.
    public static func parse(_ text: String) throws -> EditPlan {
        let candidates = jsonCandidates(in: text)
        guard !candidates.isEmpty else { throw ParseError.noJSON(text) }
        var lastError: Error?
        for c in candidates {
            do { return try JSONDecoder().decode(EditPlan.self, from: Data(c.utf8)) } catch { lastError = error }
        }
        throw ParseError.invalid(text, underlying: lastError!)
    }

    static func jsonCandidates(in text: String) -> [String] {
        var out: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { out.append(trimmed) }
        // fenced blocks
        var rest = Substring(text)
        while let start = rest.range(of: "```") {
            let afterFence = rest[start.upperBound...]
            guard let nl = afterFence.firstIndex(of: "\n") else { break }
            let body = afterFence[afterFence.index(after: nl)...]
            guard let end = body.range(of: "```") else { break }
            out.append(String(body[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = body[end.upperBound...]
        }
        // first balanced {...}
        if let obj = firstBalancedObject(in: text) { out.append(obj) }
        return out
    }

    static func firstBalancedObject(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escape = false
        for i in start..<chars.count {
            let ch = chars[i]
            if inString {
                if escape { escape = false } else if ch == "\\" { escape = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default: break
            }
        }
        return nil
    }
}

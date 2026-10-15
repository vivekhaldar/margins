import Foundation

/// A top-level block of the document as the model sees it.
public struct Block: Codable, Equatable, Sendable {
    public var id: String
    public var html: String
    /// True if this block is a pending (unreviewed) tracked change.
    public var pending: Bool

    public init(id: String, html: String, pending: Bool = false) {
        self.id = id
        self.html = html
        self.pending = pending
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        html = try c.decode(String.self, forKey: .html)
        pending = (try? c.decode(Bool.self, forKey: .pending)) ?? false
    }
}

public struct GenerationRequest: Sendable {
    public var system: String
    public var prompt: String
    public var model: String?

    public init(system: String, prompt: String, model: String? = nil) {
        self.system = system
        self.prompt = prompt
        self.model = model
    }

    /// For providers without a separate system channel (CLI agents).
    public var combined: String { system + "\n\n---\n\n" + prompt }
}

public enum PromptBuilder {
    public static let system = """
    You are the editing engine inside Margins, an app where an author refines a single document \
    by giving natural-language instructions. You do not chat. You never reply in prose. \
    You never use tools, read files, or run commands. You respond with exactly one JSON object \
    and nothing else, matching this schema:

    \(EditPlanSchema.json)

    Rules:
    - The document is a list of top-level HTML blocks, each with an id like [b3].
    - Make the smallest set of edits that fully satisfies the instruction. Leave everything else untouched.
    - "replace": html replaces the whole block (it may contain several blocks). "insertAfter": html is \
      inserted after blockId; use blockId "^" to insert at the very start. "delete": html is "".
    - html must be complete block elements: h1, h2, h3, p, ul/ol with li, blockquote, pre, table, figure. \
      Inline: strong, em, code, a, img. No classes, styles, scripts or ids.
    - Images appear as <img src="margins-asset://…" alt="…">. Keep them exactly as they are unless asked to change them.
    - Diagrams, charts and illustrations: write an inline <svg> inside <figure>, optionally followed by <figcaption>. \
      Give the svg a viewBox, a width of at most 680, a <title>, and use font-family="sans-serif". \
      Draw dark strokes and text on a transparent or white background. No scripts, event handlers, \
      <foreignObject> or external references. Existing diagrams are shown to you as inline <svg>; \
      to change one, replace its block with the edited <svg>.
    - Preserve existing links (<a href="…">) exactly. Add a link only when you are confident the URL is real.
    - If the document is empty, write a complete, well-structured first draft (start with an h1) \
      using insertAfter "^" edits.
    - Match the author's voice. Be concrete. Do not pad.
    - slug: at most 6 lowercase words naming the change (e.g. "tighten intro, add rollout plan").
    - summary: one sentence. notes: 0-3 short assumptions you made or questions for the author.
    """

    public static func editPrompt(blocks: [Block], instruction: String, focus: [String] = []) -> String {
        var s = "DOCUMENT\n"
        if blocks.isEmpty {
            s += "(empty)\n"
        } else {
            for b in blocks {
                s += "[\(b.id)]\(b.pending ? " (pending suggestion)" : "") \(b.html)\n"
            }
        }
        if !focus.isEmpty {
            s += "\nThe author has selected blocks \(focus.map { "[\($0)]" }.joined(separator: ", ")). "
            s += "Restrict edits to these blocks unless the instruction clearly requires otherwise.\n"
        }
        s += "\nINSTRUCTION\n\(instruction)\n\nReturn the JSON edit plan now."
        return s
    }

    /// Refine a single pending change. The model must return exactly one replace op for `blockId`.
    public static func refinePrompt(blocks: [Block], blockId: String, original: String, proposed: String,
                                    originalInstruction: String, refinement: String) -> String {
        var s = "DOCUMENT (for context)\n"
        for b in blocks { s += "[\(b.id)] \(b.html)\n" }
        s += """

        You previously proposed a change to block [\(blockId)] for the instruction: "\(originalInstruction)".
        ORIGINAL BLOCK: \(original.isEmpty ? "(none — this was an insertion)" : original)
        YOUR PROPOSAL: \(proposed)

        The author wants this one proposal refined: "\(refinement)"

        Return a JSON edit plan with exactly one edit: op "replace", blockId "\(blockId)", \
        html = the refined proposal. Do not touch any other block.
        """
        return s
    }
}

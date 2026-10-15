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
    /// When set (and the policy isn't `.off`), the provider runs as a tool-using agent.
    public var agent: AgentContext?

    public init(system: String, prompt: String, model: String? = nil, agent: AgentContext? = nil) {
        self.system = system
        self.prompt = prompt
        self.model = model
        self.agent = agent
    }

    /// The agent context if tools are enabled, else nil.
    public var tools: AgentContext? { agent?.policy == .off ? nil : agent }

    /// For providers without a separate system channel (CLI agents).
    public var combined: String { system + "\n\n---\n\n" + prompt }
}

public enum PromptBuilder {
    public static let system = system(tools: nil)

    /// System prompt; `tools` describes what the agent may do before answering.
    public static func system(tools: AgentContext?) -> String {
        let intro: String
        switch tools?.policy {
        case nil, .off?:
            intro = """
            You do not chat. You never reply in prose. \
            You never use tools, read files, or run commands. You respond with exactly one JSON object \
            and nothing else, matching this schema:
            """
        case let p?:
            let ws = tools!.workspace.path
            let can = p == .full
                ? "fetch web pages, search the web, run shell commands, and read and write files"
                : "fetch web pages, search the web, and read files (shell commands and file writes need the author's approval and may be denied)"
            intro = """
            You are a capable agent: before answering you may use your tools to \(can). \
            Use them whenever the instruction needs information that is not in the document — \
            e.g. read a linked page, look up facts, get a video transcript, check data. \
            Your working directory is \(ws); it belongs to this document and persists between instructions, \
            so keep downloads and scratch files there and never modify anything outside it. \
            Do not ask the author questions mid-task; make reasonable assumptions and record them in notes. \
            Do not narrate. When you are done, your FINAL message must be exactly one JSON object \
            and nothing else, matching this schema:
            """
        }
        return """
    You are the editing engine inside Margins, an app where an author refines a single document \
    by giving natural-language instructions. \(intro)

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
    - summary: one sentence. notes: 0-3 short assumptions you made or questions for the author.\(tools == nil ? "" : """

    - If you used sources (web pages, transcripts, files), cite them as links in the document where it helps the reader. \
      Never invent facts you could not verify; say what you could not access in notes.
    """)
    """
    }

    public static func editPrompt(blocks: [Block], instruction: String, focus: [String] = [],
                                  sources: [SourceMaterial] = []) -> String {
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
        if !sources.isEmpty {
            s += "\n" + sourceSection(sources)
        }
        s += "\nINSTRUCTION\n\(instruction)\n\nReturn the JSON edit plan now."
        return s
    }

    /// Material Margins already fetched for URLs in the instruction.
    public static func sourceSection(_ sources: [SourceMaterial]) -> String {
        var s = "SOURCE MATERIAL\nMargins has already fetched the following for URLs in the instruction. "
        s += "Base the document on it, link to the source URL, and do not try to fetch these URLs again.\n"
        for (i, src) in sources.enumerated() {
            s += "\n=== [S\(i + 1)] \(src.title)\(src.byline.isEmpty ? "" : " — \(src.byline)")\n"
            s += "URL: \(src.url)\nKind: \(src.kind)\(src.truncated ? " (truncated)" : "")\n<<<\n\(src.text)\n>>>\n"
        }
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

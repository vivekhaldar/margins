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
    public var reasoningEffort: ReasoningEffort?
    /// When set (and the policy isn't `.off`), the provider runs as a tool-using agent.
    public var agent: AgentContext?

    public init(system: String, prompt: String, model: String? = nil, agent: AgentContext? = nil,
                reasoningEffort: ReasoningEffort? = nil) {
        self.system = system
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
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
            let can = p == .unrestricted
                ? "fetch web pages, search the web, run any shell command, and read and write files anywhere on the author's Mac"
                : p == .full
                ? "fetch web pages, search the web, run shell commands, and read and write files"
                : "fetch web pages, search the web, and read files (shell commands and file writes need the author's approval and may be denied)"
            let outside = p == .unrestricted
                ? "You are not sandboxed: when the instruction asks, you may also act outside it on the author's machine — " +
                  "install tools under their home directory, edit their config files, ssh to their servers. Never use sudo, " +
                  "and don't delete or overwrite anything you weren't asked to. "
                : "Never modify anything outside it; if the instruction needs that (installing tools in the home directory, " +
                  "editing config files), do what you can inside it, then say so plainly and tell the author to switch " +
                  "Agent tools to \"Unrestricted\". "
            let place: String
            if tools!.project {
                place = """
                Your working directory is the author's project at \(ws). Besides editing the document, you may \
                do real work in this project when asked: implement features, fix bugs, write or change code, docs \
                and config, and run its build and tests to check your work. Make focused changes, follow the \
                project's conventions. \(outside)Do not commit or push unless asked. \
                If you cannot change files (a write or command was refused, or your sandbox is read-only), \
                say so plainly and tell the author to switch Agent tools to "Full agent". \

                """
            } else {
                place = """
                Your working directory is \(ws); it belongs to this document and persists between instructions, \
                so keep downloads and scratch files there. \(outside)\
                If the author asks you to change code or files in one of their projects, explain that no project \
                folder is set and tell them to choose one with Agent → Project Folder…. \

                """
            }
            intro = """
            You are a capable agent: before answering you may use your tools to \(can). \
            Use them whenever the instruction needs information that is not in the document — \
            e.g. read a linked page, look up facts, get a video transcript, check data. \
            \(place)Do not ask the author questions mid-task; make reasonable assumptions and record them in notes. \
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
    - summary: one sentence. notes: 0-3 short assumptions you made or questions for the author.
    - reply: "" unless the author is discussing a selected passage with you (the prompt will say so), \
      or you did work outside the document.\(tools == nil ? "" : """

    - If you used sources (web pages, transcripts, files), cite them as links in the document where it helps the reader. \
      Never invent facts you could not verify; say what you could not access in notes.
    - If you changed files or ran commands in the project, use reply for 1-3 sentences on what you did and how you \
      verified it (name the key files). Edit the document only as the instruction asks — e.g. to mark an item done \
      or describe what was built — and return no edits if it doesn't.
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

    /// Command-Enter turns a rough prompt in the document into finished prose at that location.
    public static func paragraphPrompt(blocks: [Block], blockId: String, instruction: String,
                                       sources: [SourceMaterial] = []) -> String {
        let task = """
        The author pressed Command-Enter on a rough prompt within block [\(blockId)].
        Treat the paragraph below as an instruction to carry out, then write a clean, synthesized answer \
        directly into the document, matching the surrounding voice, structure, and level of detail.
        Replace the rough prompt paragraph with the finished answer using a replace operation on \
        blockId "\(blockId)". You may return several complete HTML blocks in that replacement.
        If the prompt is inside a list, table, quote, or another larger block, preserve the rest of that \
        block and its structure; replace only the prompt's content. Leave unrelated blocks unchanged.
        Use tools when needed to research or carry out the request. If it requests project work, do the \
        work and synthesize the verified outcome into the document at the prompt's location.
        Return document edits even when the rough prompt is phrased as a question; a reply alone does \
        not fulfill this request. Do not merely polish or repeat the rough prompt.

        ROUGH PROMPT
        \(instruction)
        """
        return editPrompt(blocks: blocks, instruction: task, sources: sources)
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

    /// One earlier turn of an inline discussion.
    public struct ThreadTurn: Sendable, Equatable {
        public var message: String
        public var reply: String
        public var changed: String
        public init(message: String, reply: String, changed: String = "") {
            self.message = message
            self.reply = reply
            self.changed = changed
        }
    }

    /// The author selected a passage and is talking about it in a thread beside the text. The model
    /// decides: answer questions in `reply`, or make edits (scoped to the selection) when asked to change it.
    public static func discussPrompt(blocks: [Block], focus: [String], quote: String, history: [ThreadTurn],
                                     message: String, sources: [SourceMaterial] = []) -> String {
        var s = "DOCUMENT\n"
        if blocks.isEmpty { s += "(empty)\n" }
        for b in blocks { s += "[\(b.id)]\(b.pending ? " (pending suggestion)" : "") \(b.html)\n" }
        let location = focus.isEmpty ? "" : " (in \(focus.map { "[\($0)]" }.joined(separator: ", ")))"
        s += "\nSELECTED PASSAGE\(location)\n«\(quote.trimmingCharacters(in: .whitespacesAndNewlines))»\n"
        if !sources.isEmpty { s += "\n" + sourceSection(sources) }
        if !history.isEmpty {
            s += "\nEARLIER IN THIS THREAD\n"
            for t in history {
                s += "Author: \(t.message)\n"
                if !t.reply.isEmpty { s += "You: \(t.reply)\n" }
                if !t.changed.isEmpty { s += "(You edited the document: \(t.changed))\n" }
            }
        }
        s += """

        The author is discussing the selected passage with you in a comment thread beside the text.

        AUTHOR'S MESSAGE
        \(message)

        How to respond:
        - If the message is a question, or asks for an explanation, opinion, critique, fact-check or ideas, \
        answer it in "reply" and return no edits. Write the reply as plain text (no markdown headings), \
        concise and specific to the passage, usually under 120 words.
        - If the message asks you to change the text, make the edits, restricted to the selected blocks \
        unless the request clearly needs more, and use "reply" for one short sentence about what you changed.
        - If the message asks for work outside the document (implement, build, fix or run something in the \
        author's project — the passage may describe it), do that work with your tools, then use "reply" to say \
        what you changed and how you checked it. Edit the document only if asked to.
        - slug and summary describe the edits (or the question, if there are none).

        Return the JSON edit plan now.
        """
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

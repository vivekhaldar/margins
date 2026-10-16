import Foundation
import MarginsCore

// Headless harness for exercising providers without the UI.
//
//   margins-cli models <copilot|codex|claude|openai> [--base-url URL]
//   margins-cli edit   <provider> [--model M] [--blocks blocks.json] [--tools off|research|full] "instruction"
//   margins-cli edit   <provider> --blocks blocks.json --quote "selected text" "message"   (inline discussion)
//
// With --tools, the agent's tool calls stream to stderr; permission asks (research mode) are approved
// if --yes is given, else denied.
//
// blocks.json: [{"id":"b1","html":"<p>…</p>"}]. API key for `openai` comes from $OPENAI_API_KEY.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: margins-cli models <copilot|codex|claude|openai> [--base-url URL]
           margins-cli edit <provider> [--model M] [--blocks FILE] [--base-url URL] [--tools off|research|full] [--yes] [--quote TEXT] "instruction"

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let command = args.removeFirst()
let providerName = args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
let model = option("--model")
let blocksPath = option("--blocks")
let baseURL = option("--base-url")
let quote = option("--quote")
let policy = option("--tools").flatMap(AgentToolPolicy.init(rawValue:)) ?? .off
let autoYes = args.contains("--yes")
args.removeAll { $0 == "--yes" }

let kind: ProviderKind
switch providerName {
case "copilot": kind = .copilot
case "codex": kind = .codex
case "claude": kind = .claudeCode
case "openai": kind = .openAICompatible
default: usage()
}

var config = ProviderConfig(kind: kind)
config.baseURL = baseURL ?? "https://api.openai.com/v1"

do {
    let provider = try ProviderFactory.make(config, apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
    defer { provider.shutdown() }
    switch command {
    case "models":
        for m in try await provider.availableModels() { print(m.id.isEmpty ? "(default)" : m.id, "\t", m.name) }
    case "edit":
        guard let instruction = args.last else { usage() }
        var blocks: [Block] = []
        if let blocksPath {
            blocks = try JSONDecoder().decode([Block].self, from: Data(contentsOf: URL(fileURLWithPath: blocksPath)))
        }
        let start = Date()
        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("margins-cli-workspace")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let agent = AgentContext(policy: policy, workspace: workspace, onEvent: { e in
            switch e {
            case .step(let s): err("  [\(s.status.rawValue)] \(s.kind.rawValue): \(s.title) \(s.detail.prefix(120))")
            case .thought(let t): err("  … \(t.replacingOccurrences(of: "\n", with: " ").prefix(160))")
            }
        }, askPermission: { req in
            err("  ? permission: \(req.title) — \(req.detail) → \(autoYes ? "allow" : "deny")")
            return autoYes ? .allowOnce : .deny
        })
        var sources: [SourceMaterial] = []
        for id in YouTube.videoIDs(in: instruction) {
            do {
                let src = try await YouTube.fetch(id: id)
                err("  [done] fetch: YouTube transcript · \(src.wordCount) words — \(src.title)")
                sources.append(src)
            } catch {
                err("  [failed] fetch: YouTube \(id) — \(error.localizedDescription)")
            }
        }
        let plan = try await provider.editPlan(GenerationRequest(
            system: PromptBuilder.system(tools: policy == .off || !kind.supportsTools ? nil : agent),
            prompt: quote.map { q in
                let plain = { (h: String) in h.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                return PromptBuilder.discussPrompt(blocks: blocks, focus: blocks.filter { plain($0.html).contains(q) }.map(\.id),
                                                   quote: q, history: [], message: instruction, sources: sources)
            } ?? PromptBuilder.editPrompt(blocks: blocks, instruction: instruction, sources: sources),
            model: model, agent: agent))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        print(String(decoding: try enc.encode(plan), as: UTF8.self))
        FileHandle.standardError.write(Data(String(format: "(%.1fs via %@)\n", Date().timeIntervalSince(start), provider.displayName).utf8))
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

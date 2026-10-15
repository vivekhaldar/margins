import Foundation
import MarginsCore

// Headless harness for exercising providers without the UI.
//
//   margins-cli models <copilot|codex|claude|openai> [--base-url URL]
//   margins-cli edit   <provider> [--model M] [--blocks blocks.json] "instruction"
//
// blocks.json: [{"id":"b1","html":"<p>…</p>"}]. API key for `openai` comes from $OPENAI_API_KEY.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: margins-cli models <copilot|codex|claude|openai> [--base-url URL]
           margins-cli edit <provider> [--model M] [--blocks FILE] [--base-url URL] "instruction"

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
        let plan = try await provider.editPlan(GenerationRequest(
            system: PromptBuilder.system,
            prompt: PromptBuilder.editPrompt(blocks: blocks, instruction: instruction),
            model: model))
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

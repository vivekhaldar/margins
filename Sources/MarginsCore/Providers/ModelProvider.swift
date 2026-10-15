import Foundation

public struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name ?? id
    }
}

/// A model backend. Margins only needs one capability: given a prompt, return text
/// (which should contain an EditPlan JSON object).
public protocol ModelProvider: AnyObject {
    var kind: ProviderKind { get }
    var displayName: String { get }
    func availableModels() async throws -> [ModelInfo]
    func generate(_ request: GenerationRequest) async throws -> String
    func shutdown()
}

public extension ModelProvider {
    func shutdown() {}

    /// Generate and parse an edit plan, retrying once with the parse error fed back.
    func editPlan(_ request: GenerationRequest) async throws -> EditPlan {
        let text = try await generate(request)
        do {
            return try EditPlanParser.parse(text)
        } catch {
            var retry = request
            retry.prompt += "\n\nYour previous output was not a valid edit plan (\(error.localizedDescription)). Return ONLY the JSON object."
            return try EditPlanParser.parse(try await generate(retry))
        }
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case copilot      // GitHub Copilot subscription via `copilot --acp`
    case codex        // ChatGPT subscription via `codex exec`
    case claudeCode   // Claude Pro/Max subscription via `claude -p`
    case openAICompatible // API key: OpenAI, OpenRouter, Ollama, LM Studio, ...

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copilot: return "GitHub Copilot"
        case .codex: return "ChatGPT (Codex)"
        case .claudeCode: return "Claude (Claude Code)"
        case .openAICompatible: return "OpenAI-compatible API"
        }
    }

    public var subscriptionNote: String {
        switch self {
        case .copilot: return "Uses your Copilot subscription through the official Copilot CLI (Agent Client Protocol)."
        case .codex: return "Uses your ChatGPT Plus/Pro/Team plan through the official Codex CLI (`codex login`)."
        case .claudeCode: return "Uses your Claude Pro/Max plan through the official Claude Code CLI (`claude /login`)."
        case .openAICompatible: return "Pay-per-token API key, or a local server such as Ollama (http://localhost:11434/v1)."
        }
    }

    public var defaultBinary: String? {
        switch self {
        case .copilot: return "copilot"
        case .codex: return "codex"
        case .claudeCode: return "claude"
        case .openAICompatible: return nil
        }
    }
}

public struct ProviderConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ProviderKind
    public var name: String
    public var enabled: Bool
    /// Override path to the CLI binary (GUI apps don't inherit the shell PATH).
    public var binaryPath: String
    /// OpenAI-compatible only.
    public var baseURL: String
    /// Default model id; empty = provider default.
    public var model: String

    public init(id: UUID = UUID(), kind: ProviderKind, name: String? = nil, enabled: Bool = true,
                binaryPath: String = "", baseURL: String = "", model: String = "") {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.title
        self.enabled = enabled
        self.binaryPath = binaryPath
        self.baseURL = baseURL
        self.model = model
    }

    public static var defaults: [ProviderConfig] {
        [
            ProviderConfig(kind: .copilot),
            ProviderConfig(kind: .codex),
            ProviderConfig(kind: .claudeCode),
            ProviderConfig(kind: .openAICompatible, name: "Ollama (local)", enabled: false,
                           baseURL: "http://localhost:11434/v1"),
            ProviderConfig(kind: .openAICompatible, name: "OpenAI API", enabled: false,
                           baseURL: "https://api.openai.com/v1"),
        ]
    }
}

public enum ProviderError: LocalizedError {
    case binaryNotFound(String)
    case processFailed(String, Int32, String)
    case protocolError(String)
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let b):
            return "Couldn't find `\(b)`. Install it or set its path in Settings → Providers."
        case .processFailed(let b, let code, let err):
            return "`\(b)` exited with status \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))"
        case .protocolError(let s): return s
        case .notConfigured(let s): return s
        }
    }
}

public enum ProviderFactory {
    public static func make(_ config: ProviderConfig, apiKey: String? = nil) throws -> ModelProvider {
        func binary() throws -> URL {
            let name = config.kind.defaultBinary ?? ""
            guard let url = BinaryLocator.locate(name, override: config.binaryPath) else {
                throw ProviderError.binaryNotFound(config.binaryPath.isEmpty ? name : config.binaryPath)
            }
            return url
        }
        switch config.kind {
        case .copilot: return ACPProvider(displayName: config.name, executable: try binary(), arguments: ["--acp", "--disable-builtin-mcps"])
        case .codex: return CodexExecProvider(displayName: config.name, executable: try binary())
        case .claudeCode: return ClaudeCodeProvider(displayName: config.name, executable: try binary())
        case .openAICompatible:
            guard let url = URL(string: config.baseURL), !config.baseURL.isEmpty else {
                throw ProviderError.notConfigured("Set a base URL for \(config.name).")
            }
            return OpenAICompatibleProvider(displayName: config.name, baseURL: url, apiKey: apiKey)
        }
    }
}

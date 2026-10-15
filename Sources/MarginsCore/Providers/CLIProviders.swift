import Foundation

/// ChatGPT subscription via the official Codex CLI: `codex exec --json --output-schema … -`.
public final class CodexExecProvider: ModelProvider {
    public let kind: ProviderKind = .codex
    public let displayName: String
    private let executable: URL

    public init(displayName: String, executable: URL) {
        self.displayName = displayName
        self.executable = executable
    }

    public func availableModels() async throws -> [ModelInfo] {
        // Codex has no machine-readable model list; empty id = the CLI's configured default.
        [ModelInfo(id: "", name: "Default (from ~/.codex/config.toml)"),
         ModelInfo(id: "gpt-6.1-sol", name: "gpt-6.1-sol"),
         ModelInfo(id: "gpt-6-luna", name: "gpt-6-luna")]
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        let schemaURL = ProcessRunner.scratchDirectory().appendingPathComponent("edit-plan.schema.json")
        try EditPlanSchema.json.write(to: schemaURL, atomically: true, encoding: .utf8)
        var args = ["exec", "--json", "--output-schema", schemaURL.path, "--skip-git-repo-check",
                    "--ephemeral", "-s", "read-only", "-C", ProcessRunner.scratchDirectory().path,
                    "-c", "model_reasoning_effort=\"medium\""]
        if let m = request.model, !m.isEmpty { args += ["-m", m] }
        args.append("-")
        let r = try await ProcessRunner.run(executable, arguments: args, stdin: request.combined,
                                            cwd: ProcessRunner.scratchDirectory())
        if let msg = Self.lastAgentMessage(jsonl: r.stdout) { return msg }
        if let err = Self.firstError(jsonl: r.stdout) { throw ProviderError.protocolError("Codex: \(err)") }
        throw ProviderError.processFailed("codex", r.status, r.stderr.isEmpty ? r.stdout : r.stderr)
    }

    /// Extract the final `agent_message` text from `codex exec --json` output.
    public static func lastAgentMessage(jsonl: String) -> String? {
        var last: String?
        for line in jsonl.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "item.completed",
                  let item = obj["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else { continue }
            last = text
        }
        return last
    }

    static func firstError(jsonl: String) -> String? {
        for line in jsonl.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if type == "error" || type == "turn.failed" {
                if let m = obj["message"] as? String { return m }
                if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            }
        }
        return nil
    }
}

/// Claude Pro/Max subscription via the official Claude Code CLI in print mode.
public final class ClaudeCodeProvider: ModelProvider {
    public let kind: ProviderKind = .claudeCode
    public let displayName: String
    private let executable: URL

    public init(displayName: String, executable: URL) {
        self.displayName = displayName
        self.executable = executable
    }

    public func availableModels() async throws -> [ModelInfo] {
        [ModelInfo(id: "", name: "Default"), ModelInfo(id: "sonnet", name: "Sonnet"),
         ModelInfo(id: "opus", name: "Opus"), ModelInfo(id: "haiku", name: "Haiku")]
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        var args = ["-p", "--output-format", "json", "--json-schema", EditPlanSchema.json,
                    "--system-prompt", request.system, "--tools", ""]
        if let m = request.model, !m.isEmpty { args += ["--model", m] }
        let r = try await ProcessRunner.run(executable, arguments: args, stdin: request.prompt,
                                            cwd: ProcessRunner.scratchDirectory())
        return try Self.extract(stdout: r.stdout, status: r.status, stderr: r.stderr)
    }

    /// Parse `claude -p --output-format json` output. Structured output lands in
    /// `structured_output` (object) when `--json-schema` is honoured, else in `result` (string).
    public static func extract(stdout: String, status: Int32, stderr: String) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else {
            throw ProviderError.processFailed("claude", status, stderr.isEmpty ? stdout : stderr)
        }
        if obj["is_error"] as? Bool == true {
            throw ProviderError.protocolError("Claude Code: \(obj["result"] as? String ?? "error"). Run `claude` in a terminal and /login.")
        }
        if let so = obj["structured_output"], JSONSerialization.isValidJSONObject(so),
           let d = try? JSONSerialization.data(withJSONObject: so) {
            return String(decoding: d, as: UTF8.self)
        }
        if let r = obj["result"] as? String { return r }
        throw ProviderError.protocolError("Claude Code returned no result.")
    }
}

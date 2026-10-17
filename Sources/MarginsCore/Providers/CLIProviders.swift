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
        let tools = request.tools
        let cwd = tools?.workspace ?? ProcessRunner.scratchDirectory()
        var args = ["exec", "--json", "--output-schema", schemaURL.path, "--skip-git-repo-check",
                    "--ephemeral", "-C", cwd.path]
        args += Self.effortArguments(request.reasoningEffort)
        args += Self.policyArguments(tools?.policy ?? .off)
        if let m = request.model, !m.isEmpty { args += ["-m", m] }
        args.append("-")
        let emit = request.agent?.onEvent
        let r = try await ProcessRunner.run(executable, arguments: args, stdin: request.combined, cwd: cwd,
                                            onLine: emit.map { emit in { line in Self.events(line).forEach(emit) } })
        if Task.isCancelled { throw CancellationError() }
        if let msg = Self.lastAgentMessage(jsonl: r.stdout) { return msg }
        if let err = Self.firstError(jsonl: r.stdout) { throw ProviderError.protocolError("Codex: \(err)") }
        throw ProviderError.processFailed("codex", r.status, r.stderr.isEmpty ? r.stdout : r.stderr)
    }

    static func effortArguments(_ effort: ReasoningEffort?) -> [String] {
        guard let effort else { return [] }
        return ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""]
    }

    /// Codex enforces policy with its own OS sandbox; it never asks, so `.research` means
    /// "read-only sandbox (commands can read but not write or use the network) plus web search".
    public static func policyArguments(_ p: AgentToolPolicy) -> [String] {
        switch p {
        case .off: return ["-s", "read-only", "-c", "web_search=\"disabled\""]
        case .research: return ["-s", "read-only", "-c", "web_search=\"live\""]
        case .full: return ["-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true",
                            "-c", "web_search=\"live\""]
        case .unrestricted: return ["-s", "danger-full-access", "-c", "web_search=\"live\""]
        }
    }

    /// Progress events from one `codex exec --json` line.
    public static func events(_ line: String) -> [AgentEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String, type == "item.started" || type == "item.completed" || type == "item.updated",
              let item = obj["item"] as? [String: Any], let id = item["id"] as? String else { return [] }
        let done = type == "item.completed"
        func status() -> AgentStep.Status {
            if !done { return .running }
            if let code = item["exit_code"] as? Int, code != 0 { return .failed }
            if let s = item["status"] as? String, s == "failed" || s == "declined" { return .failed }
            return .done
        }
        switch item["type"] as? String {
        case "command_execution":
            let cmd = Self.unwrapShell(item["command"] as? String ?? "")
            return [.step(AgentStep(id: id, kind: .execute, title: "Run command", detail: cmd, status: status()))]
        case "web_search":
            let q = item["query"] as? String ?? ""
            return [.step(AgentStep(id: id, kind: .search, title: "Search the web", detail: q, status: status()))]
        case "file_change":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return [.step(AgentStep(id: id, kind: .edit, title: "Edit files",
                                    detail: paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), status: status()))]
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            return [.step(AgentStep(id: id, kind: .other, title: name.isEmpty ? "Tool" : name, status: status()))]
        case "reasoning":
            if done, let t = item["text"] as? String { return [.thought(t + "\n")] }
        case "agent_message":
            // Interim narration; the final message is the answer and starts with "{".
            if done, let t = item["text"] as? String, !t.trimmingCharacters(in: .whitespaces).hasPrefix("{") { return [.thought(t + "\n")] }
        default: break
        }
        return []
    }

    /// `/bin/zsh -lc 'echo hi'` → `echo hi`.
    static func unwrapShell(_ cmd: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where cmd.hasPrefix(prefix) {
            var rest = String(cmd.dropFirst(prefix.count))
            if rest.count >= 2, let f = rest.first, f == "'" || f == "\"", rest.last == f {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return cmd
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
        let tools = request.tools
        let cwd = tools?.workspace ?? ProcessRunner.scratchDirectory()
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--json-schema", EditPlanSchema.json,
                    "--system-prompt", request.system]
        args += Self.policyArguments(tools?.policy ?? .off)
        if let m = request.model, !m.isEmpty { args += ["--model", m] }
        let emit = request.agent?.onEvent
        let names = ToolNames()
        let r = try await ProcessRunner.run(executable, arguments: args, stdin: request.prompt, cwd: cwd,
                                            onLine: emit.map { emit in { line in Self.events(line, names: names).forEach(emit) } })
        if Task.isCancelled { throw CancellationError() }
        let last = r.stdout.split(separator: "\n").last { $0.contains("\"type\":\"result\"") }.map(String.init) ?? r.stdout
        return try Self.extract(stdout: last, status: r.status, stderr: r.stderr)
    }

    /// Claude Code can't ask Margins mid-run in print mode, so `.research` pre-approves
    /// only read-only tools and everything else is unavailable.
    public static func policyArguments(_ p: AgentToolPolicy) -> [String] {
        let read = "WebFetch,WebSearch,Read,Grep,Glob"
        switch p {
        case .off: return ["--tools", ""]
        case .research: return ["--tools", read, "--allowedTools", read, "--permission-mode", "dontAsk"]
        case .full:
            let all = read + ",Bash,Write,Edit"
            return ["--tools", all, "--allowedTools", all, "--permission-mode", "dontAsk"]
        case .unrestricted:
            let all = read + ",Bash,Write,Edit"
            return ["--tools", all, "--dangerously-skip-permissions", "--add-dir", NSHomeDirectory()]
        }
    }

    final class ToolNames: @unchecked Sendable {
        private var map: [String: (ToolKind, String, String)] = [:]
        private let lock = NSLock()
        subscript(id: String) -> (ToolKind, String, String)? {
            get { lock.lock(); defer { lock.unlock() }; return map[id] }
            set { lock.lock(); map[id] = newValue; lock.unlock() }
        }
    }

    /// Progress events from one `claude -p --output-format stream-json` line.
    static func events(_ line: String, names: ToolNames) -> [AgentEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return [] }
        var out: [AgentEvent] = []
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                      name != "StructuredOutput" else { continue }
                let (kind, title) = Self.describe(name)
                let detail = ToolInput.detail(block["input"])
                names[id] = (kind, title, detail)
                out.append(.step(AgentStep(id: id, kind: kind, title: title, detail: detail)))
            case "tool_result":
                guard let id = block["tool_use_id"] as? String, let (kind, title, detail) = names[id] else { continue }
                let failed = block["is_error"] as? Bool == true
                out.append(.step(AgentStep(id: id, kind: kind, title: title, detail: detail, status: failed ? .failed : .done)))
            case "thinking":
                if let t = block["thinking"] as? String { out.append(.thought(t + "\n")) }
            case "text":
                if obj["type"] as? String == "assistant", let t = block["text"] as? String, !t.hasPrefix("{") { out.append(.thought(t + "\n")) }
            default: break
            }
        }
        return out
    }

    static func describe(_ tool: String) -> (ToolKind, String) {
        switch tool {
        case "WebFetch": return (.fetch, "Fetch web page")
        case "WebSearch": return (.search, "Search the web")
        case "Read": return (.read, "Read file")
        case "Grep", "Glob": return (.search, "Search files")
        case "Bash": return (.execute, "Run command")
        case "Write", "Edit", "MultiEdit": return (.edit, "Edit file")
        default: return (.other, tool)
        }
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

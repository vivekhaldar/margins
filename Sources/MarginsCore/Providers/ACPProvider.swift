import Foundation

/// Minimal Agent Client Protocol (ACP) client: JSON-RPC 2.0, newline-delimited, over stdio.
/// https://agentclientprotocol.com — spoken by `copilot --acp`, Gemini CLI, and Claude Code / Codex adapters.
///
/// Margins advertises no client filesystem or terminal capabilities: the agent uses its own
/// built-in tools (web fetch, shell, file edits) in the document's workspace, and every
/// permission request is routed to a per-session handler that applies the user's tool policy.
public final class ACPClient: @unchecked Sendable {
    public typealias JSON = [String: Any]

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let queue = DispatchQueue(label: "margins.acp")
    private var buffer = Data()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var sinks: [String: (JSON) -> Void] = [:]
    private var permissionHandlers: [String: @Sendable (JSON) async -> JSON] = [:]
    private var stderrTail = ""
    public private(set) var isRunning = false

    public init(executable: URL, arguments: [String], cwd: URL) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = BinaryLocator.childEnvironment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.queue.async { self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000)) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.queue.async { self.consume(d) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.queue.async {
                self.isRunning = false
                let err = ProviderError.processFailed(executable.lastPathComponent, p.terminationStatus, self.stderrTail)
                for (_, c) in self.pending { c.resume(throwing: err) }
                self.pending.removeAll()
            }
        }
        try process.run()
        isRunning = true
    }

    deinit { terminate() }

    public func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Register a handler for `session/update` notifications of one session.
    public func onUpdate(session: String, _ handler: ((JSON) -> Void)?) {
        queue.sync { sinks[session] = handler }
    }

    /// Register a handler that answers `session/request_permission` for one session.
    /// It receives the request params and returns the `outcome` object.
    public func onPermission(session: String, _ handler: (@Sendable (JSON) async -> JSON)?) {
        queue.sync { permissionHandlers[session] = handler }
    }

    public func request(_ method: String, _ params: JSON) async throws -> ACPClient.JSON {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.isRunning else {
                    cont.resume(throwing: ProviderError.protocolError("ACP agent is not running. \(self.stderrTail)"))
                    return
                }
                self.nextId += 1
                let id = self.nextId
                self.pending[id] = cont
                self.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        }
    }

    public func notify(_ method: String, _ params: JSON) {
        queue.async { self.send(["jsonrpc": "2.0", "method": method, "params": params]) }
    }

    // MARK: - private (on queue)

    private func send(_ msg: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? JSON else { continue }
            handle(obj)
        }
    }

    func handle(_ msg: JSON) {
        let method = msg["method"] as? String
        let id = msg["id"]
        if let method, let id {
            // Agent → client request.
            if method == "session/request_permission" {
                let params = msg["params"] as? ACPClient.JSON ?? [:]
                guard let sid = params["sessionId"] as? String, let handler = permissionHandlers[sid] else {
                    send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                    return
                }
                let reqID = id as Any
                let box = UncheckedBox(params)
                Task {
                    let outcome = await handler(box.value)
                    self.queue.async { self.send(["jsonrpc": "2.0", "id": reqID, "result": ["outcome": outcome]]) }
                }
            } else {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Margins does not support \(method)"]])
            }
        } else if let method {
            if method == "session/update", let params = msg["params"] as? JSON,
               let sid = params["sessionId"] as? String, let update = params["update"] as? JSON {
                sinks[sid]?(update)
            }
        } else if let intId = (id as? Int) ?? (id as? NSNumber)?.intValue, let cont = pending.removeValue(forKey: intId) {
            if let err = msg["error"] as? JSON {
                cont.resume(throwing: ProviderError.protocolError("ACP error: \(err["message"] as? String ?? "\(err)")"))
            } else {
                cont.resume(returning: msg["result"] as? JSON ?? [:])
            }
        }
    }
}

/// Model provider backed by any ACP agent (GitHub Copilot CLI by default).
public final class ACPProvider: ModelProvider {
    public let kind: ProviderKind = .copilot
    public let displayName: String
    private let executable: URL
    private let arguments: [String]
    private var client: ACPClient?
    private var models: [ModelInfo] = []
    private let setupLock = AsyncLock()

    public init(displayName: String, executable: URL, arguments: [String]) {
        self.displayName = displayName
        self.executable = executable
        self.arguments = arguments
    }

    deinit { client?.terminate() }

    public func shutdown() {
        client?.terminate()
        client = nil
    }

    private func ready() async throws -> ACPClient {
        try await setupLock.withLock {
            if let c = client, c.isRunning { return c }
            let c = try ACPClient(executable: executable, arguments: arguments, cwd: ProcessRunner.scratchDirectory())
            _ = try await c.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "Margins", "version": "0.1.0"],
            ])
            client = c
            return c
        }
    }

    private func newSession(_ c: ACPClient, cwd: URL? = nil) async throws -> String {
        let dir = cwd ?? ProcessRunner.scratchDirectory()
        let r = try await c.request("session/new", ["cwd": dir.path, "mcpServers": []])
        guard let sid = r["sessionId"] as? String else { throw ProviderError.protocolError("ACP: no sessionId") }
        if let m = r["models"] as? [String: Any], let list = m["availableModels"] as? [[String: Any]] {
            var parsed: [ModelInfo] = list.compactMap { item in
                guard let id = item["modelId"] as? String else { return nil }
                var name = item["name"] as? String ?? id
                if let meta = item["_meta"] as? [String: Any], let usage = meta["copilotUsage"] as? String {
                    name += " · \(usage)"
                }
                return ModelInfo(id: id, name: name)
            }
            // Empty id = whatever the agent picks by default (its `currentModelId` for a fresh session).
            let current = (m["currentModelId"] as? String).flatMap { cur in
                list.first { $0["modelId"] as? String == cur }?["name"] as? String ?? cur
            }
            parsed.insert(ModelInfo(id: "", name: current.map { "Default (\($0))" } ?? "Default"), at: 0)
            models = parsed
        }
        return sid
    }

    public func availableModels() async throws -> [ModelInfo] {
        if !models.isEmpty { return models }
        let c = try await ready()
        let sid = try await newSession(c)
        c.notify("session/cancel", ["sessionId": sid])
        return models
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        let c = try await ready()
        let agent = request.agent
        let tools = request.tools
        let sid = try await newSession(c, cwd: tools?.workspace)
        defer {
            c.onUpdate(session: sid, nil)
            c.onPermission(session: sid, nil)
        }
        if let model = request.model, !model.isEmpty {
            _ = try await c.request("session/set_model", ["sessionId": sid, "modelId": model])
        }
        let collector = TextCollector()
        let emit = agent?.onEvent ?? { _ in }
        let denied = TextCollector()
        c.onUpdate(session: sid) { update in
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk":
                if let content = update["content"] as? [String: Any], let t = content["text"] as? String {
                    collector.append(t)
                }
            case "agent_thought_chunk":
                if let content = update["content"] as? [String: Any], let t = content["text"] as? String {
                    emit(.thought(t))
                }
            case "tool_call", "tool_call_update":
                // Narration before a tool call isn't the answer; the final message is.
                let said = collector.take()
                if !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(.thought(said)) }
                if let step = Self.step(from: update, denied: denied) { emit(.step(step)) }
            default: break
            }
        }
        c.onPermission(session: sid) { params in
            let call = params["toolCall"] as? ACPClient.JSON ?? [:]
            let options = params["options"] as? [ACPClient.JSON] ?? []
            let kind = ToolKind(loose: call["kind"] as? String)
            let id = call["toolCallId"] as? String ?? UUID().uuidString
            let decision: PermissionDecision
            if let agent, agent.policy != .off {
                if let auto = agent.autoDecision(for: kind) {
                    decision = auto
                } else {
                    decision = await agent.askPermission(PermissionRequest(
                        id: id, kind: kind, title: call["title"] as? String ?? kind.rawValue,
                        detail: ToolInput.detail(call["rawInput"])))
                }
            } else {
                decision = .deny
            }
            if decision == .deny {
                denied.append("\u{1}\(id)\u{1}")
                emit(.step(AgentStep(id: id, kind: kind, title: call["title"] as? String ?? kind.rawValue,
                                     detail: ToolInput.detail(call["rawInput"]), status: .denied)))
            }
            return Self.outcome(decision, options: options)
        }
        let prompt: [String: Any] = ["type": "text", "text": request.combined]
        let result = try await withTaskCancellationHandler {
            try await c.request("session/prompt", ["sessionId": sid, "prompt": [prompt]])
        } onCancel: {
            c.notify("session/cancel", ["sessionId": sid])
        }
        let stop = result["stopReason"] as? String ?? "?"
        if stop == "cancelled" || Task.isCancelled { throw CancellationError() }
        let out = collector.text
        if out.isEmpty { throw ProviderError.protocolError("Agent returned no text (stopReason: \(stop)).") }
        return out
    }

    /// Map an ACP permission decision onto one of the offered options.
    static func outcome(_ d: PermissionDecision, options: [ACPClient.JSON]) -> ACPClient.JSON {
        let wanted: [String]
        switch d {
        case .allowOnce: wanted = ["allow_once", "allow_always"]
        case .allowAlways: wanted = ["allow_always", "allow_once"]
        case .deny: wanted = ["reject_once", "reject_always"]
        }
        for k in wanted {
            if let o = options.first(where: { $0["kind"] as? String == k }), let id = o["optionId"] as? String {
                return ["outcome": "selected", "optionId": id]
            }
        }
        return ["outcome": "cancelled"]
    }

    /// Turn an ACP `tool_call` / `tool_call_update` into a step for the instruction card.
    static func step(from u: ACPClient.JSON, denied: TextCollector) -> AgentStep? {
        guard let id = u["toolCallId"] as? String else { return nil }
        let status: AgentStep.Status
        switch u["status"] as? String {
        case "completed": status = .done
        case "failed": status = denied.text.contains("\u{1}\(id)\u{1}") ? .denied : .failed
        default: status = .running
        }
        return AgentStep(id: id, kind: ToolKind(loose: u["kind"] as? String),
                         title: u["title"] as? String ?? "", detail: ToolInput.detail(u["rawInput"]), status: status)
    }
}

final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

final class TextCollector: @unchecked Sendable {
    private var parts: [String] = []
    private let lock = NSLock()
    func append(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    /// Return everything collected so far and clear it.
    func take() -> String { lock.lock(); defer { parts.removeAll(); lock.unlock() }; return parts.joined() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}

/// Serialises async critical sections.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

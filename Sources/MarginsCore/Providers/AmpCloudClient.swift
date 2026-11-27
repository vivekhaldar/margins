import Foundation

public enum AmpCloudError: Error, LocalizedError, Equatable {
    case missingBinary
    case credentialUnavailable(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .missingBinary:
            return "Amp CLI (`amp`) not found. Install it from ampcode.com and Recheck."
        case .credentialUnavailable(let detail):
            return "Amp API key unavailable: \(detail)"
        case .invalidInput(let detail):
            return detail
        }
    }
}

public enum AmpPreflightStatus: Equatable, Sendable {
    case ready(version: String)
    case missingBinary
    case credentialUnavailable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// One decoded line of `amp --stream-json` output.
public enum AmpStreamEvent: Equatable, Sendable {
    /// `system/init`: the remote thread exists.
    case initialized(threadID: String)
    /// Assistant text or tool use, shown as progress only (never terminal, including `end_turn`).
    case progress(String)
    /// `result` with `is_error: false`.
    case result(String)
    /// `result` with `is_error: true`, or a `system` error event.
    case error(message: String, subtype: String?)
    case ignored
}

/// How one Amp turn ended, from Margins' point of view.
public enum AmpTurnOutcome: Equatable, Sendable {
    case completed(threadID: String?, result: String)
    case failed(threadID: String?, message: String)
    /// The stream closed before a `result`: the remote run may still finish, but Margins never relaunches it.
    case disconnected(threadID: String?, detail: String)
    /// Detached launch accepted; Margins does not watch it.
    case submitted(threadID: String)

    public var threadID: String? {
        switch self {
        case .completed(let id, _), .failed(let id, _), .disconnected(let id, _): return id
        case .submitted(let id): return id
        }
    }
}

/// Runs Amp remote orbs (`amp -ox`). Cloud-only: never registered as a local `ProviderKind`.
public struct AmpCloudClient: Sendable {
    public static let threadURLPrefix = "https://ampcode.com/threads/"

    private let runner: CloudCommandRunner
    public let credentials: AmpCredentialProvider

    public init(runner: CloudCommandRunner = ProcessCloudCommandRunner(), credentials: AmpCredentialProvider? = nil) {
        self.runner = runner
        self.credentials = credentials ?? AmpCredentialProvider(runner: runner)
    }

    // MARK: - Commands

    public static func streamArguments(project: String) -> [String] {
        ["-ox", "--project", project, "--stream-json", "--no-archive-after-execute"]
    }

    public static func detachedArguments(project: String) -> [String] {
        ["-ox", "--project", project]
    }

    public static func continueArguments(threadID: String) -> [String] {
        ["threads", "continue", threadID, "-ox", "--stream-json"]
    }

    /// Checks the CLI and the key without launching a run. Never called on focus or wake by default.
    public func preflight() async -> AmpPreflightStatus {
        guard let amp = runner.locate("amp") else { return .missingBinary }
        let version = (try? await runner.run(amp, arguments: ["--version"], stdin: nil, cwd: nil, onLine: nil))
            .flatMap { $0.status == 0 ? AmpCredentialProvider.firstLine($0.stdout) : nil } ?? ""
        do {
            _ = try await credentials.apiKey()
            return .ready(version: version)
        } catch {
            return .credentialUnavailable(error.localizedDescription)
        }
    }

    /// `owner/repo` of the `origin` remote of the project folder.
    public func resolveProject(in directory: URL) async throws -> String {
        guard let git = runner.locate("git") else { throw AmpCloudError.invalidInput("`git` not found.") }
        let res = try await runner.run(git, arguments: ["remote", "get-url", "origin"], stdin: nil, cwd: directory, onLine: nil)
        guard res.status == 0, let project = Self.parseGitHubRemote(res.stdout) else {
            throw AmpCloudError.invalidInput("Could not determine a GitHub `owner/repo` from the `origin` remote.")
        }
        return project
    }

    /// Starts a new streamed thread. `onEvent` receives redacted events as they arrive.
    public func streamTurn(
        project: String, prompt: String, cwd: URL? = nil,
        onEvent: @escaping @Sendable (AmpStreamEvent) -> Void
    ) async throws -> AmpTurnOutcome {
        let project = try Self.validateProject(project)
        return try await runStream(Self.streamArguments(project: project), prompt: prompt, cwd: cwd, onEvent: onEvent)
    }

    /// Sends a follow-up to an existing thread.
    public func continueTurn(
        threadID: String, prompt: String, cwd: URL? = nil,
        onEvent: @escaping @Sendable (AmpStreamEvent) -> Void
    ) async throws -> AmpTurnOutcome {
        guard Self.isValidThreadID(threadID) else { throw AmpCloudError.invalidInput("Invalid Amp thread ID.") }
        return try await runStream(Self.continueArguments(threadID: threadID), prompt: prompt, cwd: cwd, onEvent: onEvent)
    }

    /// Fire-and-forget launch: one `amp` call, never retried.
    public func dispatchDetached(project: String, prompt: String, cwd: URL? = nil) async throws -> AmpTurnOutcome {
        let project = try Self.validateProject(project)
        let (amp, env, token) = try await launchContext()
        let res: ProcessResult
        do {
            res = try await runner.run(amp, arguments: Self.detachedArguments(project: project), stdin: prompt, cwd: cwd,
                                       environment: env, onLine: nil)
        } catch {
            return .failed(threadID: nil, message: AmpCredentialProvider.redact(error.localizedDescription, secret: token))
        }
        return Self.detachedOutcome(res, secret: token)
    }

    private func runStream(
        _ arguments: [String], prompt: String, cwd: URL?,
        onEvent: @escaping @Sendable (AmpStreamEvent) -> Void
    ) async throws -> AmpTurnOutcome {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AmpCloudError.invalidInput("Prompt cannot be empty.") }
        let (amp, env, token) = try await launchContext()
        let tracker = AmpStreamTracker()
        do {
            let res = try await runner.run(amp, arguments: arguments, stdin: prompt, cwd: cwd, environment: env) { line in
                let event = Self.decodeEvent(line).redacted(token)
                tracker.observe(event)
                if event != .ignored { onEvent(event) }
            }
            return Self.streamOutcome(tracker.snapshot(), res, secret: token)
        } catch {
            let seen = tracker.snapshot()
            if let terminal = seen.terminal { return terminal }
            let detail = AmpCredentialProvider.redact(error.localizedDescription, secret: token)
            if seen.threadID != nil { return .disconnected(threadID: seen.threadID, detail: detail) }
            return .failed(threadID: nil, message: detail)
        }
    }

    private func launchContext() async throws -> (URL, [String: String], String) {
        guard let amp = runner.locate("amp") else { throw AmpCloudError.missingBinary }
        let token: String
        do {
            token = try await credentials.apiKey()
        } catch {
            throw AmpCloudError.credentialUnavailable(error.localizedDescription)
        }
        var env = BinaryLocator.childEnvironment(for: amp)
        env[AmpCredentialProvider.environmentKey] = token
        return (amp, env, token)
    }
}

/// Collects the thread ID and terminal event seen on a stream (stdout is read off the caller's task).
final class AmpStreamTracker: @unchecked Sendable {
    struct Snapshot { var threadID: String?; var terminal: AmpTurnOutcome? }
    private let lock = NSLock()
    private var state = Snapshot()

    func observe(_ event: AmpStreamEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .initialized(let id):
            if state.threadID == nil { state.threadID = id }
        case .result(let text):
            if state.terminal == nil { state.terminal = .completed(threadID: state.threadID, result: text) }
        case .error(let message, let subtype):
            if state.terminal == nil {
                let detail = [subtype, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                state.terminal = .failed(threadID: state.threadID, message: detail.isEmpty ? "Amp reported an error." : detail)
            }
        case .progress, .ignored:
            break
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

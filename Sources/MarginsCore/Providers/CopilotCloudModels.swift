import Foundation

public protocol CloudCommandRunner: Sendable {
    func locate(_ name: String) -> URL?
    /// `environment` nil = the default child environment. A custom one must start from
    /// `BinaryLocator.childEnvironment(for:)` so `PATH` (node, amp, …) is preserved.
    func run(
        _ executable: URL,
        arguments: [String],
        stdin: String?,
        cwd: URL?,
        environment: [String: String]?,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult
}

extension CloudCommandRunner {
    public func run(
        _ executable: URL,
        arguments: [String],
        stdin: String?,
        cwd: URL?,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, stdin: stdin, cwd: cwd, environment: nil, onLine: onLine)
    }
}

public struct ProcessCloudCommandRunner: CloudCommandRunner {
    public init() {}

    public func locate(_ name: String) -> URL? {
        BinaryLocator.locate(name)
    }

    public func run(
        _ executable: URL,
        arguments: [String],
        stdin: String?,
        cwd: URL?,
        environment: [String: String]?,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable, arguments: arguments, stdin: stdin, cwd: cwd, environment: environment, onLine: onLine
        )
    }
}

public enum CopilotCloudAuthStatus: Equatable, Sendable {
    case authenticated(detail: String)
    case missingBinary
    case notAuthenticated(detail: String)
}

public enum CopilotCloudError: LocalizedError, Equatable, Sendable {
    case ghNotFound
    case notAuthenticated(String)
    case invalidInput(String)
    case repoNotResolved(String)
    case commandFailed(command: String, status: Int32, detail: String)
    case invalidResponse(String)
    case submissionAmbiguous(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "GitHub CLI (`gh`) was not found. Install it (e.g. `brew install gh`) and run `gh auth login`."
        case .notAuthenticated(let detail):
            return detail.isEmpty ? "GitHub CLI is not authenticated. Run `gh auth login` in Terminal." : detail
        case .invalidInput(let msg):
            return msg
        case .repoNotResolved(let detail):
            return "Could not resolve GitHub repository: \(detail)"
        case .commandFailed(let cmd, let status, let detail):
            let suffix = detail.isEmpty ? "exit \(status)" : detail
            return "`\(cmd)` failed (\(status)): \(suffix)"
        case .invalidResponse(let detail):
            return "Unexpected response from GitHub CLI: \(detail)"
        case .submissionAmbiguous(let detail):
            return "Cloud task submission did not confirm cleanly and no matching recent task was found: \(detail)"
        }
    }
}

public struct CloudRepoInfo: Equatable, Sendable {
    public var repo: String
    public var defaultBranch: String

    public init(repo: String, defaultBranch: String) {
        self.repo = repo
        self.defaultBranch = defaultBranch
    }
}

public struct CloudTaskRequest: Equatable, Sendable {
    public var repo: String
    public var baseRef: String
    public var instruction: String
    public var excerpt: String?
    public var createPullRequest: Bool
    public var model: String?
    public var customAgent: String?

    public init(
        repo: String,
        baseRef: String,
        instruction: String,
        excerpt: String? = nil,
        createPullRequest: Bool = false,
        model: String? = nil,
        customAgent: String? = nil
    ) {
        self.repo = repo
        self.baseRef = baseRef
        self.instruction = instruction
        self.excerpt = excerpt
        self.createPullRequest = createPullRequest
        self.model = model
        self.customAgent = customAgent
    }
}

public struct CloudTaskSnapshot: Equatable, Sendable {
    public var taskID: String
    public var htmlURL: String
    public var state: String
    public var sessionID: String?
    public var createdAt: Date?
    public var prompt: String?
    /// Non-empty `sessions[].prompt` values (only present on the single-task GET).
    public var sessionPrompts: [String]
    public var creatorID: Int64?

    public init(
        taskID: String,
        htmlURL: String,
        state: String,
        sessionID: String? = nil,
        createdAt: Date? = nil,
        prompt: String? = nil,
        sessionPrompts: [String] = [],
        creatorID: Int64? = nil
    ) {
        self.taskID = taskID
        self.htmlURL = htmlURL
        self.state = state
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.prompt = prompt
        self.sessionPrompts = sessionPrompts
        self.creatorID = creatorID
    }
}

public struct CloudSessionMetadata: Equatable, Sendable {
    public var state: String?
    public var completedAt: Date?
    public var pullRequestURL: String?

    public init(state: String? = nil, completedAt: Date? = nil, pullRequestURL: String? = nil) {
        self.state = state
        self.completedAt = completedAt
        self.pullRequestURL = pullRequestURL
    }
}

public enum CloudTaskState: Equatable, Sendable {
    case queued
    case inProgress
    case waitingForUser
    case idle
    case completed
    case failed
    case cancelled
    case timedOut
    /// Handed off without a live stream (Amp detached launch); Margins no longer watches it.
    case submitted
    /// The live stream closed before a result arrived; the remote outcome is unknown.
    case disconnected
    case unknown(String)

    public init(rawState: String) {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued": self = .queued
        case "in_progress": self = .inProgress
        case "waiting_for_user": self = .waitingForUser
        case "idle": self = .idle
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled", "canceled": self = .cancelled
        case "timed_out": self = .timedOut
        case "submitted": self = .submitted
        case "disconnected": self = .disconnected
        default: self = .unknown(rawState)
        }
    }

    public var rawState: String {
        switch self {
        case .queued: return "queued"
        case .inProgress: return "in_progress"
        case .waitingForUser: return "waiting_for_user"
        case .idle: return "idle"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed_out"
        case .submitted: return "submitted"
        case .disconnected: return "disconnected"
        case .unknown(let raw): return raw
        }
    }

    public var shouldPoll: Bool {
        switch self {
        case .queued, .inProgress: return true
        default: return false
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .waitingForUser, .idle: return true
        default: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut: return true
        default: return false
        }
    }

    public var intentStatus: Intent.Status {
        switch self {
        case .completed, .submitted: return .done
        case .failed, .cancelled, .timedOut, .disconnected: return .failed
        case .queued, .inProgress, .waitingForUser, .idle, .unknown: return .working
        }
    }

    public var displayLabel: String {
        switch self {
        case .queued: return "Queued"
        case .inProgress: return "In progress"
        case .waitingForUser, .idle: return "Needs attention"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .submitted: return "Submitted"
        case .disconnected: return "Outcome unknown"
        case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }

    public func notificationOutcome(
        summary: String,
        detail: String,
        error: String? = nil,
        hasEdits: Bool = false
    ) -> AgentNotificationOutcome? {
        switch self {
        case .queued, .inProgress, .submitted, .disconnected, .unknown:
            return nil
        case .waitingForUser, .idle:
            let message = detail.isEmpty ? "Cloud task is waiting for your input on GitHub." : detail
            return .permissionNeeded(title: "Copilot Cloud needs attention", detail: message)
        case .completed:
            return .completed(hasEdits: hasEdits, summary: summary, slug: "cloud task completed", reply: detail)
        case .failed, .cancelled, .timedOut:
            let fallback = "Cloud task \(displayLabel.lowercased())."
            return .failed(error: error?.isEmpty == false ? error! : (detail.isEmpty ? fallback : detail))
        }
    }
}

public enum CloudTaskFormatter {
    /// The agent's final answer from a `gh agent-task view --log` transcript (tool steps and footers removed).
    public static func extractSummary(fromLog log: String, maxChars: Int = 1200) -> String {
        CloudLogSummarizer.summary(fromLog: log, maxChars: maxChars)
    }

    public static func insertionHTML(
        intentText: String,
        reply: String?,
        log: String?,
        summary: String,
        pullRequestURL: String?,
        htmlURL: String?,
        backend: CloudBackend = .copilot
    ) -> String {
        let bodyText = [reply, summary, log.map { extractSummary(fromLog: $0) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? intentText

        var blocks: [String] = []
        let paragraphs = bodyText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for paragraph in paragraphs {
            let escaped = escapeHTML(paragraph).replacingOccurrences(of: "\n", with: "<br>")
            blocks.append("<p>\(escaped)</p>")
        }
        var links: [String] = []
        if let pr = safeWebURL(pullRequestURL) {
            links.append("<a href=\"\(escapeHTML(pr))\">Pull Request</a>")
        }
        if let task = safeWebURL(htmlURL) {
            links.append("<a href=\"\(escapeHTML(task))\">\(escapeHTML(backend.taskLinkTitle))</a>")
        }
        if !links.isEmpty {
            blocks.append("<p><em>Source: \(links.joined(separator: " · "))</em></p>")
        }
        return blocks.joined(separator: "\n")
    }

    private static func safeWebURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return raw
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

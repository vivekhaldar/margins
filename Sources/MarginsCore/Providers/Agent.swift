import Foundation

/// How much the backend agent may do while working on an instruction.
public enum AgentToolPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One-shot: no tools; the model answers from the document alone.
    case off
    /// Read-only research: fetch web pages, search the web, read files in the workspace.
    /// Anything with side effects (shell commands, writing files) must be approved.
    case research
    /// Full agent: may also run shell commands and write files in the document's workspace.
    case full
    /// No sandbox: may run any command and write anywhere the user can (home dir, config, ssh…).
    case unrestricted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off — answer from the document only"
        case .research: return "Research — web and reading; ask before commands"
        case .full: return "Full agent — commands and file changes"
        case .unrestricted: return "Unrestricted — anywhere on this Mac, no sandbox"
        }
    }

    public var shortTitle: String {
        switch self {
        case .off: return "No tools"
        case .research: return "Research"
        case .full: return "Full agent"
        case .unrestricted: return "Unrestricted"
        }
    }

    /// May change files and run commands without asking.
    public var canWrite: Bool { self == .full || self == .unrestricted }
}

/// ACP-style tool kinds (https://agentclientprotocol.com/protocol/tool-calls).
public enum ToolKind: String, Codable, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, other

    public init(loose s: String?) { self = ToolKind(rawValue: (s ?? "").lowercased()) ?? .other }

    /// Kinds with no side effects outside the agent's own context.
    public var isReadOnly: Bool { [.read, .search, .fetch, .think].contains(self) }

    public var symbol: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .think: return "brain"
        case .fetch: return "globe"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// One tool call made by the agent, as shown (and persisted) on the instruction card.
public struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed, denied }
    public var id: String
    public var kind: ToolKind
    public var title: String
    public var detail: String
    public var status: Status

    public init(id: String, kind: ToolKind, title: String, detail: String = "", status: Status = .running) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public enum AgentEvent: Sendable {
    /// A tool call started or changed. Steps with the same id replace each other.
    case step(AgentStep)
    /// Streaming reasoning / narration text (not persisted).
    case thought(String)
}

public struct PermissionRequest: Sendable, Identifiable {
    public var id: String
    public var kind: ToolKind
    public var title: String
    /// The concrete thing: a command line, a URL, a file path.
    public var detail: String
    public init(id: String, kind: ToolKind, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public enum PermissionDecision: Sendable { case allowOnce, allowAlways, deny }

/// Everything a provider needs to run as a tool-using agent.
public struct AgentContext: Sendable {
    public var policy: AgentToolPolicy
    /// Working directory for the agent: one per document, persists across instructions.
    public var workspace: URL
    /// True when `workspace` is the author's own project folder (code, docs) rather than a scratch folder.
    public var project: Bool
    public var onEvent: @Sendable (AgentEvent) -> Void
    /// Asked for side-effecting tool calls in `.research` mode (where the backend supports it).
    public var askPermission: @Sendable (PermissionRequest) async -> PermissionDecision

    public init(policy: AgentToolPolicy, workspace: URL, project: Bool = false,
                onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in },
                askPermission: @escaping @Sendable (PermissionRequest) async -> PermissionDecision = { _ in .deny }) {
        self.policy = policy
        self.workspace = workspace
        self.project = project
        self.onEvent = onEvent
        self.askPermission = askPermission
    }

    /// Default policy decision for a tool call, or nil if the user must be asked.
    public func autoDecision(for kind: ToolKind) -> PermissionDecision? {
        switch policy {
        case .off: return .deny
        case .full, .unrestricted: return .allowAlways
        case .research: return kind.isReadOnly ? .allowOnce : nil
        }
    }

    public static func workspace(for documentID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margins/Workspaces/\(documentID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// Short human-readable detail for a tool call's raw input.
enum ToolInput {
    static func detail(_ raw: Any?) -> String {
        guard let d = raw as? [String: Any] else { return "" }
        for k in ["command", "url", "query", "path", "file_path", "pattern", "description"] {
            if let s = d[k] as? String, !s.isEmpty { return String(s.prefix(300)) }
        }
        if let cmds = d["commands"] as? [String], let c = cmds.first { return String(c.prefix(300)) }
        return ""
    }
}

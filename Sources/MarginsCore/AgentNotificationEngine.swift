import Foundation

public enum AgentNotificationPreferences {
    public static let notifyOnFinishKey = "notifyOnAgentFinish"
    public static let playSoundKey = "notifyAgentPlaySound"
    public static let onlyWhenInBackgroundKey = "notifyAgentOnlyInBackground"

    public static func notifyOnFinish(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notifyOnFinishKey) == nil ? true : defaults.bool(forKey: notifyOnFinishKey)
    }

    public static func playSound(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: playSoundKey) == nil ? true : defaults.bool(forKey: playSoundKey)
    }

    public static func onlyWhenInBackground(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: onlyWhenInBackgroundKey) == nil ? true : defaults.bool(forKey: onlyWhenInBackgroundKey)
    }
}

public enum AgentNotificationOutcome: Equatable, Sendable {
    case completed(hasEdits: Bool, summary: String, slug: String, reply: String)
    case failed(error: String)
    case permissionNeeded(title: String, detail: String)
}

public struct AgentNotificationPayload: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let playSound: Bool
    public let documentURL: URL
    public let threadID: UUID?
    public let intentID: UUID?

    public init(
        identifier: String,
        title: String,
        body: String,
        playSound: Bool,
        documentURL: URL,
        threadID: UUID?,
        intentID: UUID?
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.playSound = playSound
        self.documentURL = documentURL
        self.threadID = threadID
        self.intentID = intentID
    }
}

public protocol AgentNotificationDelivery: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization()
    func deliver(_ payload: AgentNotificationPayload)
    func removeDelivered(forDocumentURL url: URL)
}

/// Decides when to deliver agent completion, failure, and permission notifications and formats their payloads.
public final class AgentNotificationCoordinator {
    private let delivery: AgentNotificationDelivery
    private let defaults: UserDefaults
    private var requestedAuthorization = false

    public init(delivery: AgentNotificationDelivery, defaults: UserDefaults = .standard) {
        self.delivery = delivery
        self.defaults = defaults
    }

    public func requestAuthorizationIfNeeded(force: Bool = false) {
        guard delivery.isAvailable else { return }
        guard force || (AgentNotificationPreferences.notifyOnFinish(in: defaults) && !requestedAuthorization) else { return }
        requestedAuthorization = true
        delivery.requestAuthorization()
    }

    public func notify(
        documentURL: URL,
        step: Int,
        intentID: UUID? = nil,
        threadID: UUID? = nil,
        outcome: AgentNotificationOutcome,
        wasCancelled: Bool = false,
        isDocumentFocused: Bool
    ) {
        guard delivery.isAvailable, !wasCancelled else { return }
        guard AgentNotificationPreferences.notifyOnFinish(in: defaults) else { return }
        if AgentNotificationPreferences.onlyWhenInBackground(in: defaults) && isDocumentFocused {
            return
        }
        let payload = Self.makePayload(
            documentURL: documentURL,
            step: step,
            intentID: intentID,
            threadID: threadID,
            outcome: outcome,
            playSound: AgentNotificationPreferences.playSound(in: defaults)
        )
        delivery.deliver(payload)
    }

    public func clearNotifications(forDocumentURL url: URL) {
        guard delivery.isAvailable else { return }
        delivery.removeDelivered(forDocumentURL: url)
    }

    public static func makePayload(
        documentURL: URL,
        step: Int,
        intentID: UUID?,
        threadID: UUID?,
        outcome: AgentNotificationOutcome,
        playSound: Bool
    ) -> AgentNotificationPayload {
        let rawName = documentURL.deletingPathExtension().lastPathComponent
        let docName = rawName.isEmpty ? "Margins" : rawName
        let docKey = documentKey(for: documentURL)
        let suffix: String
        let title: String
        let body: String

        switch outcome {
        case .completed(let hasEdits, let summary, let slug, let reply):
            suffix = "step-\(step)"
            title = docName
            if hasEdits {
                body = firstNonEmpty([summary, slug], fallback: "Changes ready to review.")
            } else {
                body = firstNonEmpty([reply, summary, slug], fallback: "Agent finished.")
            }
        case .failed(let error):
            suffix = "step-\(step)"
            title = "\(docName) · Agent failed"
            body = firstNonEmpty([error], fallback: "The agent run failed.")
        case .permissionNeeded(let toolTitle, let detail):
            suffix = "step-\(step).permission"
            title = "\(docName) · Approval needed"
            let combined = [toolTitle, detail].map(collapsed).filter { !$0.isEmpty }.joined(separator: " — ")
            body = firstNonEmpty([combined], fallback: "An agent tool call is waiting for approval.")
        }

        return AgentNotificationPayload(
            identifier: "margins.agent.\(docKey).\(suffix)",
            title: title,
            body: truncated(body, limit: 180),
            playSound: playSound,
            documentURL: documentURL.standardizedFileURL,
            threadID: threadID,
            intentID: intentID
        )
    }

    private static func documentKey(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func collapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func firstNonEmpty(_ candidates: [String], fallback: String) -> String {
        for candidate in candidates {
            let cleaned = collapsed(candidate)
            if !cleaned.isEmpty { return cleaned }
        }
        return fallback
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return String(text[..<cutoff]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

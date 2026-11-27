import Foundation

/// Pure parsing and classification for Amp runs, kept separate so it can be self-tested offline.
extension AmpCloudClient {
    // MARK: - NDJSON

    /// Decodes one `--stream-json` line leniently: unknown types and non-JSON lines are ignored.
    public static func decodeEvent(_ line: String) -> AmpStreamEvent {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return .ignored }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return .ignored }
            let id = (object["session_id"] as? String) ?? (object["thread_id"] as? String) ?? ""
            return isValidThreadID(id) ? .initialized(threadID: id) : .ignored
        case "assistant":
            return progressEvent(from: object)
        case "result":
            let subtype = object["subtype"] as? String
            let text = (object["result"] as? String) ?? (object["error"] as? String) ?? ""
            if object["is_error"] as? Bool == true { return .error(message: text, subtype: subtype) }
            return .result(text)
        default:
            return .ignored
        }
    }

    private static func progressEvent(from object: [String: Any]) -> AmpStreamEvent {
        let message = object["message"] as? [String: Any]
        let parts = message?["content"] as? [[String: Any]] ?? []
        var lines: [String] = []
        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String, let first = AmpCredentialProvider.firstLine(text) {
                    lines.append(first.count > 160 ? String(first.prefix(159)) + "…" : first)
                }
            case "tool_use":
                lines.append("→ \((part["name"] as? String) ?? "tool")")
            default:
                continue
            }
        }
        return lines.isEmpty ? .ignored : .progress(lines.joined(separator: "\n"))
    }

    // MARK: - Outcomes

    /// A `result` is terminal regardless of exit code; an initialized stream without one is `disconnected`.
    static func streamOutcome(_ seen: AmpStreamTracker.Snapshot, _ res: ProcessResult, secret: String?) -> AmpTurnOutcome {
        if let terminal = seen.terminal { return terminal }
        if let id = seen.threadID {
            return .disconnected(threadID: id, detail: "Stream closed before Amp reported a result (exit \(res.status)).")
        }
        if res.status != 0 {
            return .failed(threadID: nil, message: redactedOutput(res, secret: secret, fallback: "amp exited with status \(res.status)."))
        }
        return .disconnected(threadID: nil, detail: "amp exited without starting a thread.")
    }

    static func detachedOutcome(_ res: ProcessResult, secret: String?) -> AmpTurnOutcome {
        guard res.status == 0 else {
            return .failed(threadID: nil, message: redactedOutput(res, secret: secret, fallback: "amp exited with status \(res.status)."))
        }
        if let id = threadID(inText: res.stdout) ?? threadID(inText: res.stderr) { return .submitted(threadID: id) }
        return .disconnected(threadID: nil, detail: "amp accepted the task but printed no thread URL; check ampcode.com.")
    }

    private static func redactedOutput(_ res: ProcessResult, secret: String?, fallback: String) -> String {
        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = err.isEmpty ? res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
        let text = out.isEmpty ? fallback : String(out.prefix(2000))
        return AmpCredentialProvider.redact(text, secret: secret)
    }

    // MARK: - Threads & projects

    public static func isValidThreadID(_ id: String) -> Bool {
        id.range(of: "^T-[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    public static func threadURL(for id: String) -> String? {
        isValidThreadID(id) ? threadURLPrefix + id : nil
    }

    /// The first `https://ampcode.com/threads/T-…` in `text`, as a thread ID.
    public static func threadID(inText text: String) -> String? {
        let pattern = "https://ampcode\\.com/threads/(T-[A-Za-z0-9-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// `owner/repo` from a GitHub SSH (`git@github.com:o/r.git`, `ssh://git@github.com/o/r`) or HTTPS remote.
    public static func parseGitHubRemote(_ raw: String) -> String? {
        let remote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/", "git://github.com/"]
        guard let prefix = prefixes.first(where: { remote.lowercased().hasPrefix($0) }) else { return nil }
        var path = String(remote.dropFirst(prefix.count))
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return try? validateProject(path)
    }

    public static func validateProject(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw AmpCloudError.invalidInput("Amp project must be in `owner/repo` format.")
        }
        return trimmed
    }

    /// Prompt for a new thread (instruction + document context, read-only guardrail) or a follow-up.
    public static func packagePrompt(instruction: String, excerpt: String?) -> String {
        CopilotCloudClient.packagePrompt(for: CloudTaskRequest(
            repo: "", baseRef: "", instruction: instruction, excerpt: excerpt, createPullRequest: false
        ))
    }
}

extension AmpStreamEvent {
    func redacted(_ secret: String?) -> AmpStreamEvent {
        let r = { (text: String) in AmpCredentialProvider.redact(text, secret: secret) }
        switch self {
        case .progress(let text): return .progress(r(text))
        case .result(let text): return .result(r(text))
        case .error(let message, let subtype): return .error(message: r(message), subtype: subtype.map(r))
        case .initialized, .ignored: return self
        }
    }
}

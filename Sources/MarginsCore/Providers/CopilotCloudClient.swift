import Foundation

public struct CopilotCloudClient: Sendable {
    public static let readOnlyGuardrail =
        "IMPORTANT (Read-only mode): Do not create branches, commit changes, edit repository files, or open a pull request. Analyze the repository and provide your full answer, findings, or proposed text in your final response."

    private static let recoveryWindowSeconds: TimeInterval = 300
    private let runner: CloudCommandRunner
    private let now: @Sendable () -> Date

    public init(
        runner: CloudCommandRunner = ProcessCloudCommandRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.now = now
    }

    public func checkAuth() async -> CopilotCloudAuthStatus {
        guard let gh = runner.locate("gh") else { return .missingBinary }
        do {
            let res = try await runner.run(gh, arguments: ["auth", "status"], stdin: nil, cwd: nil, onLine: nil)
            let detail = Self.bestOutput(res)
            return res.status == 0 ? .authenticated(detail: detail) : .notAuthenticated(detail: detail)
        } catch {
            return .notAuthenticated(detail: error.localizedDescription)
        }
    }

    public func resolveRepo(in projectURL: URL) async throws -> CloudRepoInfo {
        let gh = try requireGH()
        let res = try await runner.run(
            gh,
            arguments: ["repo", "view", "--json", "nameWithOwner,defaultBranchRef"],
            stdin: nil,
            cwd: projectURL,
            onLine: nil
        )
        guard res.status == 0 else {
            throw CopilotCloudError.repoNotResolved(Self.bestOutput(res))
        }
        return try Self.parseRepoInfo(from: Data(res.stdout.utf8))
    }

    public func startTask(_ request: CloudTaskRequest) async throws -> CloudTaskSnapshot {
        let repo = try Self.validateRepo(request.repo)
        let baseRef = request.baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRef.isEmpty else {
            throw CopilotCloudError.invalidInput("Base branch (`base_ref`) is required.")
        }
        let gh = try requireGH()
        let (packagedPrompt, payloadJSON) = try Self.buildStartPayload(for: request)
        let startedAt = now()
        let endpoint = "agents/repos/\(repo)/tasks"

        do {
            let res = try await runner.run(
                gh,
                arguments: ["api", "-X", "POST", endpoint, "--input", "-"],
                stdin: payloadJSON,
                cwd: nil,
                onLine: nil
            )
            if res.status == 0 {
                if let parsed = try? Self.parseTaskSnapshot(from: Data(res.stdout.utf8)) {
                    return parsed
                }
                if let recovered = try await recoverSubmittedTask(repo: repo, prompt: packagedPrompt, since: startedAt) {
                    return recovered
                }
                throw CopilotCloudError.invalidResponse("Could not parse created task payload.")
            }
            let detail = Self.bestOutput(res)
            if let recovered = try await recoverSubmittedTask(repo: repo, prompt: packagedPrompt, since: startedAt) {
                return recovered
            }
            throw CopilotCloudError.commandFailed(command: "gh api -X POST \(endpoint)", status: res.status, detail: detail)
        } catch let error as CopilotCloudError {
            throw error
        } catch {
            if let recovered = try? await recoverSubmittedTask(repo: repo, prompt: packagedPrompt, since: startedAt) {
                return recovered
            }
            throw CopilotCloudError.submissionAmbiguous(error.localizedDescription)
        }
    }

    public func listRecentTasks(repo rawRepo: String, perPage: Int = 20) async throws -> [CloudTaskSnapshot] {
        let repo = try Self.validateRepo(rawRepo)
        let gh = try requireGH()
        let clamped = max(1, min(perPage, 100))
        let endpoint = "agents/repos/\(repo)/tasks?per_page=\(clamped)"
        let res = try await runner.run(gh, arguments: ["api", endpoint], stdin: nil, cwd: nil, onLine: nil)
        guard res.status == 0 else {
            throw CopilotCloudError.commandFailed(command: "gh api \(endpoint)", status: res.status, detail: Self.bestOutput(res))
        }
        return try Self.parseTaskList(from: Data(res.stdout.utf8))
    }

    public func fetchTask(repo rawRepo: String, id rawID: String) async throws -> CloudTaskSnapshot {
        let repo = try Self.validateRepo(rawRepo)
        let id = try Self.validateIdentifier(rawID, label: "task ID")
        let gh = try requireGH()
        let endpoint = "agents/repos/\(repo)/tasks/\(id)"
        let res = try await runner.run(gh, arguments: ["api", endpoint], stdin: nil, cwd: nil, onLine: nil)
        guard res.status == 0 else {
            throw CopilotCloudError.commandFailed(command: "gh api \(endpoint)", status: res.status, detail: Self.bestOutput(res))
        }
        return try Self.parseTaskSnapshot(from: Data(res.stdout.utf8))
    }

    public func fetchSessionLog(repo rawRepo: String, sessionID rawSessionID: String) async throws -> String {
        let repo = try Self.validateRepo(rawRepo)
        let sessionID = try Self.validateIdentifier(rawSessionID, label: "session ID")
        let gh = try requireGH()
        let res = try await runner.run(
            gh,
            arguments: ["agent-task", "view", "-R", repo, sessionID, "--log"],
            stdin: nil,
            cwd: nil,
            onLine: nil
        )
        guard res.status == 0 else {
            throw CopilotCloudError.commandFailed(command: "gh agent-task view --log", status: res.status, detail: Self.bestOutput(res))
        }
        return res.stdout
    }

    public func streamSessionLog(
        repo rawRepo: String,
        sessionID rawSessionID: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let repo = try Self.validateRepo(rawRepo)
        let sessionID = try Self.validateIdentifier(rawSessionID, label: "session ID")
        let gh = try requireGH()
        let res = try await runner.run(
            gh,
            arguments: ["agent-task", "view", "-R", repo, sessionID, "--log", "--follow"],
            stdin: nil,
            cwd: nil,
            onLine: onLine
        )
        guard res.status == 0 else {
            throw CopilotCloudError.commandFailed(command: "gh agent-task view --log --follow", status: res.status, detail: Self.bestOutput(res))
        }
        return res.stdout
    }

    public func fetchSessionMetadata(repo rawRepo: String, sessionID rawSessionID: String) async throws -> CloudSessionMetadata {
        let repo = try Self.validateRepo(rawRepo)
        let sessionID = try Self.validateIdentifier(rawSessionID, label: "session ID")
        let gh = try requireGH()
        let res = try await runner.run(
            gh,
            arguments: ["agent-task", "view", "-R", repo, sessionID, "--json", "state,completedAt,pullRequestUrl"],
            stdin: nil,
            cwd: nil,
            onLine: nil
        )
        guard res.status == 0 else {
            throw CopilotCloudError.commandFailed(command: "gh agent-task view --json", status: res.status, detail: Self.bestOutput(res))
        }
        return try Self.parseSessionMetadata(from: Data(res.stdout.utf8))
    }

    // MARK: - Prompt & Payload Helpers

    public static func packagePrompt(for request: CloudTaskRequest) -> String {
        var sections: [String] = []
        let instruction = request.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty { sections.append(instruction) }
        if let excerpt = request.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty {
            sections.append(
                "Document context (from Margins; the cloud agent only sees the GitHub repository):\n\(excerpt)"
            )
        }
        if !request.createPullRequest {
            sections.append(readOnlyGuardrail)
        }
        return sections.joined(separator: "\n\n")
    }

    public static func buildStartPayload(for request: CloudTaskRequest) throws -> (prompt: String, json: String) {
        let prompt = packagePrompt(for: request)
        guard !prompt.isEmpty else {
            throw CopilotCloudError.invalidInput("Prompt cannot be empty.")
        }
        var payload: [String: Any] = [
            "base_ref": request.baseRef.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompt": prompt,
            "create_pull_request": request.createPullRequest,
        ]
        if let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            payload["model"] = model
        }
        if let customAgent = request.customAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !customAgent.isEmpty {
            payload["custom_agent"] = customAgent
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CopilotCloudError.invalidResponse("Failed to encode task request JSON.")
        }
        return (prompt, json)
    }

    // MARK: - Parsing

    public static func parseRepoInfo(from data: Data) throws -> CloudRepoInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nameWithOwner = obj["nameWithOwner"] as? String, !nameWithOwner.isEmpty else {
            throw CopilotCloudError.invalidResponse("Missing `nameWithOwner` in `gh repo view` output.")
        }
        let branchRef = obj["defaultBranchRef"] as? [String: Any]
        let defaultBranch = (branchRef?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudRepoInfo(repo: nameWithOwner, defaultBranch: (defaultBranch?.isEmpty == false ? defaultBranch! : "main"))
    }

    public static func parseTaskSnapshot(from data: Data) throws -> CloudTaskSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotCloudError.invalidResponse("Expected JSON object for cloud task.")
        }
        return try parseTaskObject(obj)
    }

    public static func parseTaskList(from data: Data) throws -> [CloudTaskSnapshot] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw CopilotCloudError.invalidResponse("Expected JSON task list.")
        }
        let rawList: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rawList = array
        } else if let dict = json as? [String: Any], let tasks = (dict["tasks"] ?? dict["items"]) as? [[String: Any]] {
            rawList = tasks
        } else {
            throw CopilotCloudError.invalidResponse("Unrecognized task list payload.")
        }
        return rawList.compactMap { try? parseTaskObject($0) }
    }

    public static func parseSessionMetadata(from data: Data) throws -> CloudSessionMetadata {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotCloudError.invalidResponse("Expected JSON object for session metadata.")
        }
        let state = nonEmptyString(obj["state"])
        let completedAt = nonEmptyString(obj["completedAt"] ?? obj["completed_at"]).flatMap(parseISO8601)
        let prURL = nonEmptyString(obj["pullRequestUrl"] ?? obj["pull_request_url"])
        return CloudSessionMetadata(state: state, completedAt: completedAt, pullRequestURL: prURL)
    }

    // MARK: - Private Helpers

    private func requireGH() throws -> URL {
        guard let url = runner.locate("gh") else { throw CopilotCloudError.ghNotFound }
        return url
    }

    private func recoverSubmittedTask(repo: String, prompt: String, since startedAt: Date) async throws -> CloudTaskSnapshot? {
        let recent = try await listRecentTasks(repo: repo, perPage: 20)
        let normalizedTarget = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let earliest = startedAt.addingTimeInterval(-Self.recoveryWindowSeconds)
        return recent.first { task in
            guard let candidate = task.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  candidate == normalizedTarget else { return false }
            if let created = task.createdAt { return created >= earliest }
            return true
        }
    }

    private static func parseTaskObject(_ obj: [String: Any]) throws -> CloudTaskSnapshot {
        guard let taskID = nonEmptyString(obj["id"] ?? obj["task_id"]) else {
            throw CopilotCloudError.invalidResponse("Missing `id` in task payload.")
        }
        let htmlURL = nonEmptyString(obj["html_url"] ?? obj["htmlUrl"]) ?? ""
        let state = nonEmptyString(obj["state"] ?? obj["status"]) ?? "queued"
        let createdAt = nonEmptyString(obj["created_at"] ?? obj["createdAt"]).flatMap(parseISO8601)
        let prompt = nonEmptyString(obj["prompt"])
        let sessionID = newestSessionID(in: obj["sessions"] as? [[String: Any]] ?? [])
            ?? nonEmptyString(obj["session_id"] ?? obj["sessionId"])
        return CloudTaskSnapshot(
            taskID: taskID,
            htmlURL: htmlURL,
            state: state,
            sessionID: sessionID,
            createdAt: createdAt,
            prompt: prompt
        )
    }

    private static func newestSessionID(in sessions: [[String: Any]]) -> String? {
        guard !sessions.isEmpty else { return nil }
        let indexed = sessions.enumerated().compactMap { index, item -> (index: Int, id: String, date: Date?)? in
            guard let id = nonEmptyString(item["id"] ?? item["session_id"] ?? item["sessionId"]) else { return nil }
            let rawDate = nonEmptyString(item["updated_at"] ?? item["created_at"] ?? item["started_at"] ?? item["createdAt"])
            return (index, id, rawDate.flatMap(parseISO8601))
        }
        guard !indexed.isEmpty else { return nil }
        let newest = indexed.max { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?): return l == r ? lhs.index < rhs.index : l < r
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil): return lhs.index < rhs.index
            }
        }
        return newest?.id
    }

    private static func validateRepo(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw CopilotCloudError.invalidInput("Repository must be in `owner/repo` format.")
        }
        return trimmed
    }

    private static func validateIdentifier(_ raw: String, label: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else {
            throw CopilotCloudError.invalidInput("Invalid \(label).")
        }
        return trimmed
    }

    private static func bestOutput(_ res: ProcessResult) -> String {
        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}

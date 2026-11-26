import Foundation

/// Accumulates one `gh agent-task view --log --follow` stream. A fresh process replays the whole log
/// from the start, so lines are buffered until the replay catches up with what is already displayed;
/// this avoids flashing a truncated log (and duplicating lines) on every reconnect.
public struct CloudLogStreamAccumulator: Equatable, Sendable {
    public private(set) var text = ""
    private let existingLength: Int
    private var published = false

    public init(existing: String?) {
        existingLength = existing?.count ?? 0
    }

    /// Appends a line; returns the full log to display, or nil while still replaying older content.
    public mutating func append(_ line: String) -> String? {
        text += text.isEmpty ? line : "\n" + line
        if !published && text.count < existingLength { return nil }
        published = true
        return text
    }
}

/// Why Margins is re-checking active cloud tasks.
public enum CloudReconcileTrigger: Equatable, Sendable {
    /// Window became key: cheap catch-up, never disturbs a live watcher.
    case focus
    /// System woke from sleep: `gh` children may be wedged on dead sockets, so restart them.
    case wake
    /// Document opened / app launched: no watcher can exist yet.
    case open
}

public enum CloudWatcherPolicy {
    /// Whether to (re)start the poll + `--log --follow` watcher for an active task.
    public static func shouldStartWatcher(trigger: CloudReconcileTrigger, watcherRunning: Bool) -> Bool {
        switch trigger {
        case .focus, .open: return !watcherRunning
        case .wake: return true
        }
    }
}

/// Extracts the agent's final prose answer from a `gh agent-task view --log` transcript.
/// The transcript is glamour-rendered markdown interleaved with tool steps (titles followed by code or
/// JSON blocks); the answer is the run of prose paragraphs after the last tool step.
enum CloudLogSummarizer {
    static func summary(fromLog log: String, maxChars: Int) -> String {
        let paragraphs = splitParagraphs(log)
        var answer: [[String]] = []
        var sawProse = false
        for paragraph in paragraphs.reversed() {
            let kind = classify(paragraph)
            if kind == .noise { if sawProse { break } else { continue } }
            if kind == .footer { continue }
            sawProse = true
            answer.insert(paragraph, at: 0)
        }
        let rendered = answer.map(unwrap).filter { !$0.isEmpty }
        return truncate(rendered, maxChars: maxChars)
    }

    private enum Kind { case prose, noise, footer }

    /// Tool-step titles gh prints as a one-line paragraph before the step's code/JSON block.
    private static let toolTitlePrefixes = [
        "Bash:", "Run Bash command", "View ", "Edit:", "Create:", "Thought", "Progress update",
        "Call to ", "Run CodeQL", "Send input to Bash", "Read logs from Bash", "Stop Bash", "Output:", "Input:",
        "Get file contents", "Search ", "Navigate ", "Take screenshot", "Click ", "Type ", "Reply to comment",
        "Store memory", "Read ", "Run ", "Fetch ", "List ", "Create pull request",
    ]
    /// Titles that are unambiguous even inside a longer paragraph.
    private static let strongToolTitlePrefixes = ["Bash:", "Edit:", "Create:", "Output:", "Input:", "Call to "]
    private static let footerMarkers = [
        "For detailed session logs, try:", "To follow session logs, try:", "gh agent-task view",
        "View this session on GitHub:", "premium request",
    ]

    private static func splitParagraphs(_ log: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for raw in log.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func classify(_ paragraph: [String]) -> Kind {
        let first = paragraph[0].trimmingCharacters(in: .whitespaces)
        if footerMarkers.contains(where: { first.contains($0) }) { return .footer }
        if strongToolTitlePrefixes.contains(where: { first.hasPrefix($0) }) { return .noise }
        if paragraph.count == 1, !first.hasSuffix("."), toolTitlePrefixes.contains(where: { first.hasPrefix($0) }) {
            return .noise
        }
        if paragraph.contains(where: isCodeLine) { return .noise }
        return .prose
    }

    private static func isCodeLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = raw.prefix { $0 == " " }.count
        if line.hasPrefix("```") || line.hasPrefix("$ ") { return true }
        if line == "{" || line == "}" || line.hasPrefix("{\"") || line.hasPrefix("},") { return true }
        // Glamour indents body text by 2; code blocks sit noticeably deeper than surrounding prose.
        return indent >= 6 && !isListOrTable(line)
    }

    private static func isListOrTable(_ line: String) -> Bool {
        line.hasPrefix("•") || line.hasPrefix("- ") || line.hasPrefix("* ") || isTableLine(line)
            || line.range(of: "^[0-9]+[.)] ", options: .regularExpression) != nil
    }

    private static func isTableLine(_ line: String) -> Bool {
        line.contains("│") || line.contains("|") || line.contains("─") || line.contains("┼")
    }

    /// Joins terminal hard-wraps back into sentences but keeps list items and table rows on their own lines.
    private static func unwrap(_ paragraph: [String]) -> String {
        var lines: [String] = []
        for raw in paragraph {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let last = lines.last, !isListOrTable(line), !isTableLine(last) {
                lines[lines.count - 1] = last + " " + line
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Cuts at a paragraph boundary when possible; never splits a table. A lone oversized prose paragraph
    /// is cut at a word boundary with an ellipsis.
    private static func truncate(_ paragraphs: [String], maxChars: Int) -> String {
        var kept: [String] = []
        var length = 0
        for paragraph in paragraphs {
            let added = paragraph.count + (kept.isEmpty ? 0 : 2)
            if length + added > maxChars { break }
            kept.append(paragraph)
            length += added
        }
        if !kept.isEmpty { return kept.joined(separator: "\n\n") }
        guard let first = paragraphs.first else { return "" }
        let rows = first.components(separatedBy: "\n")
        if rows.contains(where: isTableLine) {
            var fitted: [String] = []
            for row in rows where (fitted + [row]).joined(separator: "\n").count <= maxChars { fitted.append(row) }
            return fitted.joined(separator: "\n")
        }
        let limit = max(0, maxChars - 1)
        guard first.count > limit else { return first }
        let prefix = first.prefix(limit)
        let cut = prefix.lastIndex(where: { $0.isWhitespace }).map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

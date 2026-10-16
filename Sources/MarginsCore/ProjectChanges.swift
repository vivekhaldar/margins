import Foundation

/// Which files in a git working tree an agent run touched: compare `git status` (plus each listed
/// file's modification time) before and after. Pre-existing uncommitted changes aren't reported
/// unless the run modified them again.
public enum ProjectChanges {
    public typealias Snapshot = [String: Date]

    /// Nil when `folder` isn't inside a git work tree (or git is unavailable).
    public static func snapshot(_ folder: URL) -> Snapshot? {
        guard let root = git(["rev-parse", "--show-toplevel"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty, let out = git(["status", "--porcelain=v1", "-z", "-uall"], in: folder) else { return nil }
        let rootURL = URL(fileURLWithPath: root)
        var snap: Snapshot = [:]
        for path in paths(porcelainZ: out) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: rootURL.appendingPathComponent(path).path)
            snap[path] = attrs?[.modificationDate] as? Date ?? .distantPast
        }
        return snap
    }

    /// Paths that are new, gone, or changed between two snapshots, sorted.
    public static func changed(from before: Snapshot, to after: Snapshot) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }

    /// Paths from `git status --porcelain=v1 -z` output ("XY path\0", renames "R  new\0old\0").
    public static func paths(porcelainZ s: String) -> [String] {
        var out: [String] = []
        var parts = s.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let e = parts.popFirst() {
            guard e.count > 3 else { continue }
            let xy = e.prefix(2)
            out.append(String(e.dropFirst(3)))
            if xy.contains("R") || xy.contains("C") { _ = parts.popFirst() }
        }
        return out
    }

    private static func git(_ args: [String], in dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

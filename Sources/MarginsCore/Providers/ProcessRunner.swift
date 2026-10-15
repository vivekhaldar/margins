import Foundation

/// Finds CLI binaries. Apps launched from Finder get a minimal PATH, so we search
/// common install locations and fall back to asking a login shell.
public enum BinaryLocator {
    private static var cache: [String: URL] = [:]
    private static let lock = NSLock()

    public static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                 "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    public static func locate(_ name: String, override: String = "") -> URL? {
        let fm = FileManager.default
        if !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard !name.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name], fm.isExecutableFile(atPath: hit.path) { return hit }
        for dir in searchDirectories {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) {
                let u = URL(fileURLWithPath: p)
                cache[name] = u
                return u
            }
        }
        if let p = loginShellLookup(name), fm.isExecutableFile(atPath: p) {
            let u = URL(fileURLWithPath: p)
            cache[name] = u
            return u
        }
        return nil
    }

    private static func loginShellLookup(_ name: String) -> String? {
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.hasPrefix("/") == true) ? s : nil
    }

    /// Environment for child processes: inherit, but make sure PATH includes the usual dirs
    /// (CLIs like `codex` are node scripts that need `node` on PATH).
    public static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirectories.joined(separator: ":")
        return env
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunner {
    /// Run a process to completion, feeding `stdin`, collecting stdout/stderr concurrently.
    public static func run(_ executable: URL, arguments: [String], stdin: String? = nil,
                           cwd: URL? = nil, environment: [String: String]? = nil) async throws -> ProcessResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment ?? BinaryLocator.childEnvironment
        if let cwd { p.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                let group = DispatchGroup()
                let outData = DataBox(), errData = DataBox()
                group.enter()
                DispatchQueue.global().async {
                    outData.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                p.terminationHandler = { proc in
                    group.notify(queue: .global()) {
                        cont.resume(returning: ProcessResult(
                            status: proc.terminationStatus,
                            stdout: String(decoding: outData.data, as: UTF8.self),
                            stderr: String(decoding: errData.data, as: UTF8.self)))
                    }
                }
                do {
                    try p.run()
                } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    cont.resume(throwing: error)
                    return
                }
                if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inPipe.fileHandleForWriting.close()
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    public static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

import Foundation

/// Finds CLI binaries. Apps launched from Finder get a minimal PATH, so we merge the
/// user's login shell PATH with common install locations and fall back to a shell lookup.
public enum BinaryLocator {
    private static var cache: [String: URL] = [:]
    private static let lock = NSLock()
    private static let minimalSystemPath: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    private static let supportedShellNames: Set<String> = ["zsh", "bash", "sh", "ksh", "dash", "fish"]
    private static let cachedLoginShellPath: [String] = loadLoginShellPath()

    public static var searchDirectories: [String] {
        mergedSearchDirectories(
            inheritedPath: ProcessInfo.processInfo.environment["PATH"],
            loginShellDirectories: cachedLoginShellPath,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    public static func locate(_ name: String, override: String = "") -> URL? {
        let fm = FileManager.default
        if !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard !name.isEmpty else { return nil }
        lock.lock()
        let cached = cache[name]
        lock.unlock()
        if let hit = cached, fm.isExecutableFile(atPath: hit.path) { return hit }
        for dir in searchDirectories {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) {
                let u = URL(fileURLWithPath: p)
                lock.lock(); cache[name] = u; lock.unlock()
                return u
            }
        }
        if let p = loginShellLookup(name), fm.isExecutableFile(atPath: p) {
            let u = URL(fileURLWithPath: p)
            lock.lock(); cache[name] = u; lock.unlock()
            return u
        }
        return nil
    }

    /// Environment for child processes: inherit, with PATH augmented from the user's login shell
    /// and common install locations (CLIs like `copilot` and `codex` are node scripts that need
    /// `node` on PATH).
    public static var childEnvironment: [String: String] {
        childEnvironment(for: nil)
    }

    public static func childEnvironment(for executable: URL?) -> [String: String] {
        let extra = executable.map { [$0.deletingLastPathComponent().path] } ?? []
        return childEnvironment(
            base: ProcessInfo.processInfo.environment,
            loginShellDirectories: cachedLoginShellPath,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            extraDirectories: extra
        )
    }

    static func childEnvironment(
        base: [String: String],
        loginShellDirectories: [String],
        home: String,
        extraDirectories: [String] = []
    ) -> [String: String] {
        var env = base
        env["PATH"] = mergedSearchDirectories(
            inheritedPath: base["PATH"],
            loginShellDirectories: loginShellDirectories,
            home: home,
            extraDirectories: extraDirectories
        ).joined(separator: ":")
        return env
    }

    static func fallbackDirectories(home: String) -> [String] {
        [
            "\(home)/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    static func splitPath(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    static func mergedSearchDirectories(
        inheritedPath: String?,
        loginShellDirectories: [String],
        home: String,
        extraDirectories: [String] = []
    ) -> [String] {
        let inherited = splitPath(inheritedPath)
        let fallbacks = fallbackDirectories(home: home)
        let hasMinimalInheritedPath = inherited.isEmpty || inherited.allSatisfy { minimalSystemPath.contains($0) }

        var dirs: [String] = []
        if hasMinimalInheritedPath {
            // GUI launches inherit only minimal system dirs; prefer the user's login shell PATH
            // and user/Homebrew locations ahead of /usr/bin.
            dirs += loginShellDirectories
            dirs += fallbacks
            dirs += inherited
        } else {
            dirs += inherited
            dirs += loginShellDirectories
            dirs += fallbacks
        }
        dirs += extraDirectories

        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func loginShellURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL {
        if let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           shell.hasPrefix("/"),
           isExecutable(shell) {
            let name = URL(fileURLWithPath: shell).lastPathComponent
            if supportedShellNames.contains(name) {
                return URL(fileURLWithPath: shell)
            }
        }
        return URL(fileURLWithPath: "/bin/zsh")
    }

    static func loginShellPathCommand(for shell: URL, startMarker: String, endMarker: String) -> String {
        if shell.lastPathComponent == "fish" {
            return "printf '%s' '\(startMarker)'; /usr/bin/printenv PATH; printf '%s' '\(endMarker)'"
        }
        return "printf '%s%s%s' '\(startMarker)' \"$PATH\" '\(endMarker)'"
    }

    static func extractMarkedOutput(_ output: String, startMarker: String, endMarker: String) -> String? {
        guard let startRange = output.range(of: startMarker),
              let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex) else {
            return nil
        }
        return String(output[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .newlines)
    }

    static func loadLoginShellPath(
        shell: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5.0
    ) -> [String] {
        let shellURL = shell ?? loginShellURL(environment: environment)
        let id = UUID().uuidString
        let start = "__MARGINS_PATH_START_\(id)__"
        let end = "__MARGINS_PATH_END_\(id)__"
        let cmd = loginShellPathCommand(for: shellURL, startMarker: start, endMarker: end)
        guard let raw = runShellCommand(shell: shellURL, arguments: ["-l", "-c", cmd], environment: environment, timeout: timeout),
              let extracted = extractMarkedOutput(raw, startMarker: start, endMarker: end) else {
            return []
        }
        return splitPath(extracted)
    }

    private static func loginShellLookup(_ name: String) -> String? {
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        let shellURL = loginShellURL()
        let id = UUID().uuidString
        let start = "__MARGINS_WHICH_START_\(id)__"
        let end = "__MARGINS_WHICH_END_\(id)__"
        let cmd = "printf '%s' '\(start)'; command -v '\(name)'; printf '%s' '\(end)'"
        guard let raw = runShellCommand(shell: shellURL, arguments: ["-l", "-c", cmd]),
              let extracted = extractMarkedOutput(raw, startMarker: start, endMarker: end) else {
            return nil
        }
        let path = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    static func runShellCommand(
        shell: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5.0
    ) -> String? {
        let p = Process()
        p.executableURL = shell
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        let box = DataBox()

        p.terminationHandler = { _ in exited.signal() }

        do {
            try p.run()
        } catch {
            return nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if p.isRunning { p.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                let pid = p.processIdentifier
                if pid > 0, p.isRunning { kill(pid, SIGKILL) }
                _ = exited.wait(timeout: .now() + 0.5)
            }
            return nil
        }

        guard readDone.wait(timeout: .now() + 1.0) == .success else { return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunner {
    /// Run a process to completion, feeding `stdin`, collecting stdout/stderr concurrently.
    /// `onLine` (optional) receives each stdout line as it arrives, for streaming progress.
    public static func run(_ executable: URL, arguments: [String], stdin: String? = nil,
                           cwd: URL? = nil, environment: [String: String]? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment ?? BinaryLocator.childEnvironment(for: executable)
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
                    let h = outPipe.fileHandleForReading
                    if let onLine {
                        var pending = Data()
                        while true {
                            let chunk = h.availableData
                            if chunk.isEmpty { break }
                            outData.data.append(chunk)
                            pending.append(chunk)
                            while let nl = pending.firstIndex(of: 0x0A) {
                                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                                pending.removeSubrange(pending.startIndex...nl)
                                if !line.isEmpty { onLine(line) }
                            }
                        }
                        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                    } else {
                        outData.data = h.readDataToEndOfFile()
                    }
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

import Foundation

public enum AmpCredentialError: Error, LocalizedError, Equatable {
    /// Neither `pass` nor `AMP_API_KEY` produced a key.
    case unavailable(String)
    /// `pass` (gpg / pinentry) did not answer in time.
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail
        case .timedOut:
            return "Timed out reading `pass \(AmpCredentialProvider.passEntry)`. Unlock gpg (pinentry-mac) and Recheck."
        }
    }
}

/// Supplies the Amp API key for cloud runs. The key is read from `pass AMPCODE/API_KEY` (falling back to
/// `AMP_API_KEY` in Margins' own environment), kept only in memory, and only ever handed to `amp` through
/// its child environment — never arguments, stdin, documents, logs or errors.
public actor AmpCredentialProvider {
    public static let passEntry = "AMPCODE/API_KEY"
    public static let environmentKey = "AMP_API_KEY"

    private let runner: CloudCommandRunner
    private let environment: [String: String]
    private let timeout: TimeInterval
    private var cached: String?

    public init(
        runner: CloudCommandRunner = ProcessCloudCommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) {
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    /// Returns the cached key, or reads it once from `pass` / the environment.
    public func apiKey() async throws -> String {
        if let cached { return cached }
        let key = try await loadKey()
        cached = key
        return key
    }

    /// Drops the in-memory key so the next run (or Recheck) reads it again.
    public func invalidate() {
        cached = nil
    }

    private func loadKey() async throws -> String {
        var passFailure: AmpCredentialError?
        if let pass = runner.locate("pass") {
            do {
                if let key = try await readPass(pass) { return key }
                passFailure = .unavailable("`pass \(Self.passEntry)` returned no key.")
            } catch let error as AmpCredentialError {
                passFailure = error
            } catch {
                passFailure = .unavailable("`pass \(Self.passEntry)` failed.")
            }
        }
        if let key = Self.firstLine(environment[Self.environmentKey] ?? "") { return key }
        throw passFailure ?? .unavailable(
            "`pass` not found and \(Self.environmentKey) is not set. Store the key with `pass insert \(Self.passEntry)`."
        )
    }

    private func readPass(_ pass: URL) async throws -> String? {
        let runner = runner
        let result = try await Self.withTimeout(timeout) {
            try await runner.run(pass, arguments: ["show", Self.passEntry], stdin: nil, cwd: nil, onLine: nil)
        }
        guard result.status == 0 else {
            // stderr from gpg never contains the secret, but keep it short and generic.
            throw AmpCredentialError.unavailable(
                "`pass \(Self.passEntry)` failed (exit \(result.status)). Unlock gpg (pinentry-mac) and Recheck."
            )
        }
        return Self.firstLine(result.stdout)
    }

    /// First trimmed, non-empty line (pass entries may carry metadata on later lines).
    public static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Replaces every occurrence of `secret` with a placeholder.
    public static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    /// Races `operation` against a timer without waiting for a stuck operation (e.g. `pass` blocked on
    /// pinentry) to unwind: the loser is cancelled, which terminates the child process.
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let work = Task {
                    do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if gate.resume(.failure(AmpCredentialError.timedOut)) { work.cancel() }
                }
                gate.onFinish { work.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var finished = false
    private var cleanup: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func onFinish(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            body()
            return
        }
        cleanup = body
        lock.unlock()
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let continuation = self.continuation
        let cleanup = self.cleanup
        if continuation == nil { pending = result }
        lock.unlock()
        continuation?.resume(with: result)
        cleanup?()
        return true
    }
}

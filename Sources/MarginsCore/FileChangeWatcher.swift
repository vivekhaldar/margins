import CryptoKit
import Foundation

/// Watches a document file on disk for external modifications (including atomic replacements
/// by cloud sync clients or background sync) while ignoring the app's own writes.
public final class FileChangeWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.vivekhaldar.margins.filewatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var watchedURL: URL?
    private var lastKnownDigest: Data?
    private var pendingCheck: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let onExternalChange: @Sendable (URL) -> Void

    public init(debounceInterval: TimeInterval = 0.2, onExternalChange: @escaping @Sendable (URL) -> Void) {
        self.debounceInterval = debounceInterval
        self.onExternalChange = onExternalChange
    }

    deinit {
        stop()
    }

    public func watch(_ url: URL) {
        let standardized = url.standardizedFileURL
        stop()

        let dir = standardized.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let initialDigest = Self.digest(of: standardized)

        lock.lock()
        watchedURL = standardized
        lastKnownDigest = initialDigest
        dirFD = fd
        lock.unlock()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleCheck()
        }
        src.setCancelHandler {
            close(fd)
        }

        lock.lock()
        source = src
        lock.unlock()
        src.resume()
    }

    /// Record bytes written by Margins itself so the ensuing filesystem event is ignored.
    public func markSelfWrite(_ data: Data) {
        let hash = Data(SHA256.hash(data: data))
        lock.lock()
        lastKnownDigest = hash
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        pendingCheck?.cancel()
        pendingCheck = nil
        let src = source
        source = nil
        watchedURL = nil
        dirFD = -1
        lock.unlock()
        src?.cancel()
    }

    private func scheduleCheck() {
        lock.lock()
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateChange()
        }
        pendingCheck = item
        let delay = debounceInterval
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func evaluateChange() {
        lock.lock()
        guard let url = watchedURL else {
            lock.unlock()
            return
        }
        let previous = lastKnownDigest
        lock.unlock()

        guard let current = Self.digest(of: url) else { return }
        guard current != previous else { return }

        lock.lock()
        guard watchedURL == url else {
            lock.unlock()
            return
        }
        lastKnownDigest = current
        lock.unlock()

        onExternalChange(url)
    }

    public static func digest(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}

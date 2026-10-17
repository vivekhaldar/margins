import Foundation

/// The last set of open document windows, independent of macOS's global Resume setting.
public struct WindowSession: Codable, Equatable {
    public struct Window: Codable, Equatable {
        public var url: URL
        public var frame: String
        public var miniaturized: Bool

        public init(url: URL, frame: String, miniaturized: Bool = false) {
            self.url = url.standardizedFileURL
            self.frame = frame
            self.miniaturized = miniaturized
        }
    }

    public var windows: [Window]
    public var activeURL: URL?

    public init(windows: [Window] = [], activeURL: URL? = nil) {
        self.windows = windows
        self.activeURL = activeURL?.standardizedFileURL
    }

    /// Missing or unreadable documents must not prevent the other windows from reopening.
    public func restorable(canOpen: (URL) -> Bool) -> WindowSession {
        var seen: Set<URL> = []
        let valid = windows.filter {
            $0.url.isFileURL && seen.insert($0.url.standardizedFileURL).inserted && canOpen($0.url)
        }
        return WindowSession(windows: valid, activeURL: valid.first {
            $0.url.standardizedFileURL == activeURL?.standardizedFileURL
        }?.url)
    }
}

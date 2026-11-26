import CryptoKit
import Foundation

extension SyncEngine {
    func writeConflictCopy(localData: Data, title: String) throws -> URL {
        let name = Self.conflictFilename(title: title, hostName: hostName, date: now())
        let url = uniqueLocalURL(preferredName: name)
        try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        try localData.write(to: url, options: .atomic)
        return url
    }

    public static func conflictFilename(title: String, hostName: String, date: Date) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = safeTitle.isEmpty ? "Untitled" : String(safeTitle.prefix(60))
        let shortHost = hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = shortHost.isEmpty ? "Mac" : shortHost
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return "\(baseTitle) (Conflict on \(host) \(df.string(from: date))).\(MarginsDocument.fileExtension)"
    }

    func renameLocalFile(entry: inout SyncEntry, to newName: String) {
        let fm = FileManager.default
        let oldURL = entry.localURL(in: documentsFolder)
        let newURL = uniqueLocalURL(preferredName: newName)
        guard oldURL != newURL else { return }
        if fm.fileExists(atPath: oldURL.path) {
            try? fm.moveItem(at: oldURL, to: newURL)
            let oldMD = oldURL.deletingPathExtension().appendingPathExtension("md")
            let newMD = newURL.deletingPathExtension().appendingPathExtension("md")
            if fm.fileExists(atPath: oldMD.path) { try? fm.moveItem(at: oldMD, to: newMD) }
            let oldAssets = oldURL.deletingPathExtension().appendingPathExtension("assets")
            let newAssets = newURL.deletingPathExtension().appendingPathExtension("assets")
            if fm.fileExists(atPath: oldAssets.path) { try? fm.moveItem(at: oldAssets, to: newAssets) }
        }
        entry.filename = newURL.lastPathComponent
    }

    func uniqueLocalURL(preferredName: String) -> URL {
        let fm = FileManager.default
        let candidate = documentsFolder.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let next = documentsFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }

    static func regenerateMarkdown(for doc: MarginsDocument, at url: URL) {
        guard !doc.versions.isEmpty || !doc.html.isEmpty else { return }
        let mdURL = url.deletingPathExtension().appendingPathExtension("md")
        let assetsFolder = url.deletingPathExtension().appendingPathExtension("assets")
        let folderName = assetsFolder.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetsFolder.lastPathComponent
        let used = MarginsDocument.assetIDs(in: doc.html).filter { doc.assets[$0] != nil }
        let fm = FileManager.default
        if used.isEmpty {
            try? fm.removeItem(at: assetsFolder)
        } else {
            try? fm.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
            for id in used {
                if let asset = doc.assets[id] {
                    let assetURL = assetsFolder.appendingPathComponent("\(id).\(asset.fileExtension)")
                    if !fm.fileExists(atPath: assetURL.path) {
                        try? asset.data.write(to: assetURL, options: .atomic)
                    }
                }
            }
        }
        let md = MarkdownExporter.markdown(fromHTML: doc.html) { src in
            guard let id = MarginsDocument.assetID(fromSrc: src), let a = doc.assets[id] else { return src }
            return "\(folderName)/\(id).\(a.fileExtension)"
        }
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

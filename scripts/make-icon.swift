// Renders assets/AppIcon.svg → assets/AppIcon.icns using WebKit (no extra tools needed).
//   swift scripts/make-icon.swift
import AppKit
import WebKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let svg = root.appendingPathComponent("assets/AppIcon.svg")
let out = root.appendingPathComponent("assets/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    func start() {
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        let markup = try! String(contentsOf: svg, encoding: .utf8)
        web.loadHTMLString("<html><body style='margin:0;background:transparent'>\(markup)</body></html>", baseURL: nil)
    }
    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            w.takeSnapshot(with: nil) { image, error in
                guard let image else { fatalError("snapshot failed: \(String(describing: error))") }
                self.write(image); exit(0)
            }
        }
    }
    func png(_ image: NSImage, _ px: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    func write(_ image: NSImage) {
        let fm = FileManager.default
        try? fm.removeItem(at: iconset)
        try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try! png(image, size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try! png(image, size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try! png(image, 1024).write(to: root.appendingPathComponent("assets/AppIcon.png"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
        try! p.run(); p.waitUntilExit()
        try? fm.removeItem(at: iconset)
        print("Wrote \(out.path)")
    }
}

let app = NSApplication.shared
let r = Renderer()
r.start()
app.run()

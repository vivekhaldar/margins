// Generates assets/AppIcon.png and AppIcon.icns from the Pencil & Spark source PNG.
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("assets/AppIcon-source.png")
let out = root.appendingPathComponent("assets/AppIcon.icns")
let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("MarginsIcon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")

guard let image = NSImage(contentsOf: source) else {
    fatalError("Cannot load \(source.path)")
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

try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    try png(image, size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(image, size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(image, 1024).write(to: root.appendingPathComponent("assets/AppIcon.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}
print("Wrote assets/AppIcon.png and \(out.path)")

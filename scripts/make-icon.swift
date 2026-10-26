// Generate the neutral Harness Desk icon (original artwork, MIT).
// Usage: swiftc -framework Cocoa -o /tmp/make-icon scripts/make-icon.swift
//        /tmp/make-icon Resources/icon-source.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let inset: CGFloat = 56
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let background = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.055, green: 0.075, blue: 0.120, alpha: 1),
    NSColor(srgbRed: 0.100, green: 0.140, blue: 0.220, alpha: 1),
])!
gradient.draw(in: background, angle: -90)

NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08).setStroke()
background.lineWidth = 2
background.stroke()

// A terminal prompt: "> _"
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 330, y: 650))
chevron.line(to: NSPoint(x: 480, y: 512))
chevron.line(to: NSPoint(x: 330, y: 374))
chevron.lineWidth = 64
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
NSColor.white.setStroke()
chevron.stroke()

let underscore = NSBezierPath()
underscore.move(to: NSPoint(x: 548, y: 374))
underscore.line(to: NSPoint(x: 720, y: 374))
underscore.lineWidth = 64
underscore.lineCapStyle = .round
NSColor(srgbRed: 0.36, green: 0.78, blue: 1.00, alpha: 1).setStroke()
underscore.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon rendering failed\n".utf8))
    exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-source.png"
do {
    try png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
} catch {
    FileHandle.standardError.write(Data("could not write \(output): \(error)\n".utf8))
    exit(1)
}

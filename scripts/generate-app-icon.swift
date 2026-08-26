#!/usr/bin/swift
import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/StayAwake/Assets.xcassets/AppIcon.appiconset"

let sizes: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(size: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to create bitmap for size \(size)")
    }

    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let dimension = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    let backgroundPath = NSBezierPath(
        roundedRect: rect.insetBy(dx: dimension * 0.04, dy: dimension * 0.04),
        xRadius: dimension * 0.22,
        yRadius: dimension * 0.22
    )

    NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.16, alpha: 1).setFill()
    backgroundPath.fill()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.38, green: 0.22, blue: 0.12, alpha: 1),
    ])
    gradient?.draw(in: backgroundPath, angle: 270)

    if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: dimension * 0.46, weight: .regular)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        let symbolSize = configured.size
        let symbolRect = NSRect(
            x: (dimension - symbolSize.width) / 2,
            y: (dimension - symbolSize.height) / 2 - dimension * 0.02,
            width: symbolSize.width,
            height: symbolSize.height
        )

        NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.84, alpha: 1).set()
        configured.draw(in: symbolRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateAppIcon", code: 1)
    }
    try png.write(to: url)
}

let fileManager = FileManager.default
try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

for entry in sizes {
    let rep = renderIcon(size: entry.size)
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(entry.name)
    try savePNG(rep, to: url)
    print("Wrote \(entry.name) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

print("Done.")

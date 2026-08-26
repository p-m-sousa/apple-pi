#!/usr/bin/env swift

import AppKit
import Foundation

enum BrandAssetError: Error, CustomStringConvertible {
    case invalidArguments
    case unreadableImage(URL)
    case bitmapCreationFailed(Int)
    case pngEncodingFailed(Int)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: generate_brand_assets.swift <source-png> <repository-root>"
        case .unreadableImage(let url):
            return "Unable to read source image at \(url.path)"
        case .bitmapCreationFailed(let size):
            return "Unable to create a \(size)x\(size) bitmap"
        case .pngEncodingFailed(let size):
            return "Unable to encode a \(size)x\(size) PNG"
        }
    }
}

private let iconSizes = [16, 32, 64, 128, 256, 512, 1024]
private let canvasInsetFraction = 52.0 / 1024.0
private let cornerRadiusFraction = 208.0 / 1024.0

func renderIcon(source: NSImage, size: Int) throws -> Data {
    guard let representation = NSBitmapImageRep(
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
        throw BrandAssetError.bitmapCreationFailed(size)
    }

    representation.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        throw BrandAssetError.bitmapCreationFailed(size)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let inset = CGFloat(size) * canvasInsetFraction
    let destination = NSRect(
        x: inset,
        y: inset,
        width: CGFloat(size) - (inset * 2),
        height: CGFloat(size) - (inset * 2)
    )
    let clip = NSBezierPath(
        roundedRect: destination,
        xRadius: CGFloat(size) * cornerRadiusFraction,
        yRadius: CGFloat(size) * cornerRadiusFraction
    )
    clip.addClip()

    source.draw(
        in: destination,
        from: .zero,
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw BrandAssetError.pngEncodingFailed(size)
    }
    return data
}

func writeIcon(source: NSImage, size: Int, destination: URL) throws {
    let data = try renderIcon(source: source, size: size)
    try data.write(to: destination, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw BrandAssetError.invalidArguments
    }

    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let repositoryRoot = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    guard let source = NSImage(contentsOf: sourceURL) else {
        throw BrandAssetError.unreadableImage(sourceURL)
    }

    let appIconDirectory = repositoryRoot
        .appendingPathComponent("ApplePi/Resources/Assets.xcassets/AppIcon.appiconset")
    for size in iconSizes {
        try writeIcon(
            source: source,
            size: size,
            destination: appIconDirectory.appendingPathComponent("apple-pi-icon-\(size).png")
        )
    }

    let markDirectory = repositoryRoot
        .appendingPathComponent("ApplePi/Resources/Assets.xcassets/ApplePiMark.imageset")
    try writeIcon(
        source: source,
        size: 256,
        destination: markDirectory.appendingPathComponent("apple-pi-mark.png")
    )
    try writeIcon(
        source: source,
        size: 512,
        destination: markDirectory.appendingPathComponent("apple-pi-mark@2x.png")
    )

    print("Generated ApplePi app icon and brand mark assets from \(sourceURL.lastPathComponent)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

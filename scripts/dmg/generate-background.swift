#!/usr/bin/env swift
// Generates background.png (800x400) and background@2x.png (1600x800)
// for the Agent Deck DMG installer.
//
// Usage:
//   swift scripts/dmg/generate-background.swift              # uses scripts/dmg/source.*
//   swift scripts/dmg/generate-background.swift my-image.jpg # override
//
// What it does:
//   1. Loads any image format (jpg, png, heic, …). Defaults to source artwork
//      committed alongside this script (`scripts/dmg/source.{jpg,png,heic}`).
//   2. Center-crops it to 2:1 aspect.
//   3. Scales to 800x400 and 1600x800.
//   4. Composites soft white capsule backgrounds behind the "Agent Deck"
//      and "Applications" labels so they stay readable against busy art.
//
// The capsule positions are derived from create-dmg's --icon coordinates
// in scripts/package-dmg.sh / .github/workflows/release.yml. If those move,
// update Layout below.

import Foundation
import AppKit

// MARK: - Geometry

let baseSize = CGSize(width: 800, height: 400)

enum Layout {
    // create-dmg's `--icon X Y` translates to an AppleScript
    // `set position of item to {X, Y}` — and Finder's `position` is the
    // icon's CENTER, not its top-left. Empirically (verified by tracing
    // capsule placement against rendered DMGs), the icon center lands at
    // approximately the X,Y passed to --icon, with a small (~15pt) downward
    // offset baked in by Finder's icon view padding.
    static let appIconCenter  = CGPoint(x: 180, y: 175)
    static let dropIconCenter = CGPoint(x: 620, y: 175)

    // --icon-size 96.
    static let iconSize: CGFloat = 96
    static var iconRadius: CGFloat { iconSize / 2 }

    // Label sits BELOW the icon glyph in window display. Tuned to match
    // Finder default icon-view label baseline.
    static let labelGapBelowIcon: CGFloat = 14
    static let labelHeight: CGFloat = 24

    static var appLabelCenter: CGPoint {
        CGPoint(
            x: appIconCenter.x,
            y: appIconCenter.y + iconRadius + labelGapBelowIcon + labelHeight / 2
        )
    }
    static var dropLabelCenter: CGPoint {
        CGPoint(
            x: dropIconCenter.x,
            y: dropIconCenter.y + iconRadius + labelGapBelowIcon + labelHeight / 2
        )
    }

    static let appLabelWidth: CGFloat = 118   // "Agent Deck" + padding
    static let dropLabelWidth: CGFloat = 130  // "Applications" + padding
}

// Convert window (top-origin) coordinates to Core Graphics (bottom-origin).
func toCG(_ windowPoint: CGPoint) -> CGPoint {
    CGPoint(x: windowPoint.x, y: baseSize.height - windowPoint.y)
}

// MARK: - Image loading & crop

func loadSource(_ path: String) throws -> CGImage {
    let resolved = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: resolved)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(
            domain: "dmg-bg", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot decode image at \(resolved)"]
        )
    }
    return img
}

/// Center-crop the source image to match the 2:1 target aspect ratio.
func centerCropTo2x1(_ src: CGImage) -> CGImage? {
    let w = CGFloat(src.width)
    let h = CGFloat(src.height)
    let targetAspect = baseSize.width / baseSize.height   // 2.0
    let srcAspect = w / h

    var crop = CGRect(x: 0, y: 0, width: w, height: h)
    if srcAspect > targetAspect {
        let newW = h * targetAspect
        crop.origin.x = (w - newW) / 2
        crop.size.width = newW
    } else {
        let newH = w / targetAspect
        crop.origin.y = (h - newH) / 2
        crop.size.height = newH
    }
    return src.cropping(to: crop)
}

// MARK: - Compose

func renderComposed(source: CGImage, scale: CGFloat, to url: URL) throws {
    let pixelSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(pixelSize.width),
        height: Int(pixelSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "dmg-bg", code: 2) }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Pass-through: paint the source image to fill the 800x400 canvas.
    // Any label-readability treatment (halo, capsule, light band) should
    // be baked into the source artwork itself — Finder renders icon labels
    // on top with no way to control their colour from a DMG.
    ctx.draw(source, in: CGRect(origin: .zero, size: baseSize))

    guard let cgImage = ctx.makeImage() else { throw NSError(domain: "dmg-bg", code: 3) }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = baseSize
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "dmg-bg", code: 4)
    }
    try data.write(to: url)
}

// Soft white radial halo behind the icon's label row. Fades into the
// underlying artwork so it reads as glow, not as a UI element.
func drawLabelHalo(in ctx: CGContext, around center: CGPoint) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    // Wide ellipse: wider than tall, to match the shape of a label.
    let radiusX: CGFloat = 80
    let radiusY: CGFloat = 30
    ctx.saveGState()
    // Clip to an ellipse to constrain the gradient.
    let ellipse = CGRect(
        x: center.x - radiusX, y: center.y - radiusY,
        width: radiusX * 2, height: radiusY * 2
    )
    ctx.addEllipse(in: ellipse)
    ctx.clip()
    // Stretch the gradient by scaling: paint a circular gradient into a
    // CTM that's been scaled to make it elliptical.
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: radiusX / radiusY, y: 1)
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawRadialGradient(
        gradient,
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: radiusY,
        options: []
    )
    ctx.restoreGState()
}

func drawLabelCapsule(in ctx: CGContext, center: CGPoint, width: CGFloat) {
    let height = Layout.labelHeight
    let rect = CGRect(
        x: center.x - width / 2,
        y: center.y - height / 2,
        width: width,
        height: height
    )
    let radius = height / 2
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: radius, cornerHeight: radius,
        transform: nil
    )

    // 1. Outer neon-glow ring tinted to the brand (cyan, complementing the
    //    cyan halftone on the right of the artwork — also helps anchor the
    //    pill against the navy background).
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: 14,
        color: CGColor(srgbRed: 0.40, green: 0.90, blue: 1.00, alpha: 0.55)
    )
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Bright white pill body (opaque enough that dark labels read clearly).
    ctx.saveGState()
    ctx.setFillColor(CGColor(srgbRed: 0.985, green: 0.985, blue: 0.990, alpha: 0.97))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // 3. Top inner-highlight stroke for premium feel.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(0.5)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    // 4. Faint cyan hairline on the bottom edge — tiny detail that ties
    //    the pill to the artwork's halftone accents.
    ctx.saveGState()
    let bottomY = rect.minY + 1
    ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 0.35))
    ctx.setLineWidth(0.8)
    ctx.move(to: CGPoint(x: rect.minX + radius, y: bottomY))
    ctx.addLine(to: CGPoint(x: rect.maxX - radius, y: bottomY))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Entry point

let args = CommandLine.arguments
let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("scripts/dmg")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func resolveSourcePath() -> String? {
    if args.count >= 2 { return args[1] }
    // Default: look for source.{jpg,jpeg,png,heic} next to the script.
    let fm = FileManager.default
    for ext in ["jpg", "jpeg", "png", "heic", "webp"] {
        let candidate = outputDir.appendingPathComponent("source.\(ext)")
        if fm.fileExists(atPath: candidate.path) { return candidate.path }
    }
    return nil
}

guard let sourcePath = resolveSourcePath() else {
    FileHandle.standardError.write(Data(
        """
        No source image found.
        Either pass one as an arg, or drop `source.jpg` into scripts/dmg/:

          swift scripts/dmg/generate-background.swift my-image.jpg

        """.utf8
    ))
    exit(2)
}

let source = try loadSource(sourcePath)
guard let cropped = centerCropTo2x1(source) else {
    FileHandle.standardError.write(Data("Failed to crop source image\n".utf8))
    exit(3)
}

try renderComposed(source: cropped, scale: 1, to: outputDir.appendingPathComponent("background.png"))
try renderComposed(source: cropped, scale: 2, to: outputDir.appendingPathComponent("background@2x.png"))

print("Wrote background.png + background@2x.png from \(sourcePath)")

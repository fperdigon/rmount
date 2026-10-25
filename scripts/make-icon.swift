#!/usr/bin/env swift
// Draws the RMount app icon (a drive labeled "RM" on an indigo tile) and writes it as a PNG.
// Usage: scripts/make-icon.swift <size> <out.png>
// scripts/make-icon.sh builds the .icns and docs/icon.png from it.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]), size > 0 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <size> <out.png>\n".utf8))
    exit(2)
}

let indigo = NSColor(srgbRed: 0x5B / 255, green: 0x4B / 255, blue: 0xDB / 255, alpha: 1)
let white = NSColor.white

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let gc = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
let ctx = gc.cgContext

// Design space is 180x180 with y pointing down. macOS app icons keep the tile at 80% of the
// canvas, centred, so it matches the system's icon grid.
let canvas = CGFloat(size)
let tile = canvas * 0.8
ctx.translateBy(x: (canvas - tile) / 2, y: canvas - (canvas - tile) / 2)
ctx.scaleBy(x: tile / 180, y: -tile / 180)

func fill(_ color: NSColor, _ path: CGPath) {
    ctx.setFillColor(color.cgColor)
    ctx.addPath(path)
    ctx.fillPath()
}

func stroke(_ color: NSColor, width: CGFloat, _ path: CGPath) {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

fill(indigo, CGPath(roundedRect: CGRect(x: 0, y: 0, width: 180, height: 180), cornerWidth: 40, cornerHeight: 40, transform: nil))
fill(white, CGPath(roundedRect: CGRect(x: 34, y: 40, width: 112, height: 60), cornerWidth: 18, cornerHeight: 18, transform: nil))

// "R": stem, bowl, leg.
let r = CGMutablePath()
r.move(to: CGPoint(x: 56, y: 56)); r.addLine(to: CGPoint(x: 56, y: 84))
r.move(to: CGPoint(x: 56, y: 56)); r.addLine(to: CGPoint(x: 68, y: 56))
let k: CGFloat = 0.5523 * 7
r.addCurve(to: CGPoint(x: 75, y: 63), control1: CGPoint(x: 68 + k, y: 56), control2: CGPoint(x: 75, y: 63 - k))
r.addCurve(to: CGPoint(x: 68, y: 70), control1: CGPoint(x: 75, y: 63 + k), control2: CGPoint(x: 68 + k, y: 70))
r.addLine(to: CGPoint(x: 56, y: 70))
r.move(to: CGPoint(x: 65, y: 70)); r.addLine(to: CGPoint(x: 74, y: 84))
stroke(indigo, width: 6, r)

// "M".
let m = CGMutablePath()
m.move(to: CGPoint(x: 88, y: 84)); m.addLine(to: CGPoint(x: 88, y: 56))
m.addLine(to: CGPoint(x: 99, y: 70)); m.addLine(to: CGPoint(x: 110, y: 56)); m.addLine(to: CGPoint(x: 110, y: 84))
stroke(indigo, width: 6, m)

// Network stem and base under the drive.
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 90, y: 100)); stem.addLine(to: CGPoint(x: 90, y: 132))
stem.move(to: CGPoint(x: 52, y: 132)); stem.addLine(to: CGPoint(x: 128, y: 132))
stroke(white, width: 8, stem)
fill(white, CGPath(ellipseIn: CGRect(x: 81, y: 123, width: 18, height: 18), transform: nil))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))

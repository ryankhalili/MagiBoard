#!/usr/bin/env swift
// Original MagiBoard artwork drawn from basic geometry. No SF Symbol paths or third-party assets.
import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
NSGradient(starting: NSColor(calibratedRed: 0.29, green: 0.29, blue: 0.88, alpha: 1),
           ending: NSColor(calibratedRed: 0.19, green: 0.19, blue: 0.66, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -70)
context.setLineCap(.round); context.setLineJoin(.round)
func book(_ rect: CGRect, lean: CGFloat = 0, shade: CGFloat = 1) {
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.minY)
    context.rotate(by: lean)
    let r = CGRect(x: -rect.width / 2, y: 0, width: rect.width, height: rect.height)
    let cover = CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)
    context.setFillColor(NSColor.white.withAlphaComponent(shade).cgColor)
    context.addPath(cover); context.fillPath()
    context.setStrokeColor(NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.76, alpha: 1).cgColor)
    context.setLineWidth(13)
    context.move(to: CGPoint(x: r.minX + 27, y: 40)); context.addLine(to: CGPoint(x: r.minX + 27, y: r.maxY - 40)); context.strokePath()
    context.setLineWidth(10)
    context.move(to: CGPoint(x: r.minX + 53, y: 61)); context.addLine(to: CGPoint(x: r.maxX - 25, y: 61)); context.strokePath()
    context.restoreGState()
}
book(CGRect(x: 206, y: 227, width: 150, height: 444), shade: 0.92)
book(CGRect(x: 389, y: 227, width: 172, height: 568))
book(CGRect(x: 641, y: 228, width: 150, height: 454), lean: 0.16, shade: 0.96)
// A small original four-point light mark connects the notebook silhouette to Magic Pen.
let star = CGMutablePath()
let center = CGPoint(x: 752, y: 784)
for (index, point) in [(0.0,62.0),(16.0,17.0),(61.0,0.0),(16.0,-17.0),(0.0,-62.0),(-16.0,-17.0),(-61.0,0.0),(-16.0,17.0)].enumerated() {
    let p = CGPoint(x: center.x + point.0, y: center.y + point.1)
    if index == 0 { star.move(to: p) } else { star.addLine(to: p) }
}
star.closeSubpath(); context.setFillColor(NSColor.white.cgColor); context.addPath(star); context.fillPath()
NSGraphicsContext.restoreGraphicsState()
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "CanvasStudio/Assets.xcassets/AppIcon.appiconset/Icon.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

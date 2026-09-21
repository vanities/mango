// Renders the 1024×1024 app icon: a mango on a warm gradient, its highlight shaped like the
// gutter of an open book. Dark and tinted variants are written alongside.
//   swift scripts/render-icon.swift Mango/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let pixels = 1024
let size = CGFloat(pixels)

enum Variant: String {
    case light, dark, tinted
}

func render(_ variant: Variant, to path: String) {
    guard let cgContext = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: false)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    let background: NSGradient
    let skin: NSGradient
    let leafColor: NSColor

    switch variant {
    case .light:
        background = NSGradient(colors: [
            NSColor(srgbRed: 1.00, green: 0.85, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.97, green: 0.62, blue: 0.20, alpha: 1),
        ])!
        skin = NSGradient(colors: [
            NSColor(srgbRed: 1.00, green: 0.80, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.38, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.79, green: 0.19, blue: 0.24, alpha: 1),
        ])!
        leafColor = NSColor(srgbRed: 0.24, green: 0.55, blue: 0.29, alpha: 1)
    case .dark:
        background = NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.11, blue: 0.06, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.05, blue: 0.03, alpha: 1),
        ])!
        skin = NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.72, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.86, green: 0.31, blue: 0.16, alpha: 1),
            NSColor(srgbRed: 0.60, green: 0.13, blue: 0.18, alpha: 1),
        ])!
        leafColor = NSColor(srgbRed: 0.32, green: 0.63, blue: 0.36, alpha: 1)
    case .tinted:
        background = NSGradient(colors: [NSColor(white: 0.10, alpha: 1), NSColor(white: 0.04, alpha: 1)])!
        skin = NSGradient(colors: [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.62, alpha: 1)])!
        leafColor = NSColor(white: 0.80, alpha: 1)
    }

    background.draw(in: canvas, angle: -70)

    // The mango: a lopsided oval, rotated, fatter at the bottom.
    let body = NSBezierPath()
    let cx = size * 0.50, cy = size * 0.46
    let rx = size * 0.30, ry = size * 0.335
    body.move(to: NSPoint(x: cx - rx * 0.10, y: cy + ry))
    body.curve(to: NSPoint(x: cx + rx, y: cy - ry * 0.05),
               controlPoint1: NSPoint(x: cx + rx * 0.75, y: cy + ry * 0.92),
               controlPoint2: NSPoint(x: cx + rx * 1.05, y: cy + ry * 0.48))
    body.curve(to: NSPoint(x: cx - rx * 0.22, y: cy - ry),
               controlPoint1: NSPoint(x: cx + rx * 0.95, y: cy - ry * 0.68),
               controlPoint2: NSPoint(x: cx + rx * 0.36, y: cy - ry)) 
    body.curve(to: NSPoint(x: cx - rx * 1.02, y: cy + ry * 0.10),
               controlPoint1: NSPoint(x: cx - rx * 0.78, y: cy - ry),
               controlPoint2: NSPoint(x: cx - rx * 1.05, y: cy - ry * 0.42))
    body.curve(to: NSPoint(x: cx - rx * 0.10, y: cy + ry),
               controlPoint1: NSPoint(x: cx - rx * 0.99, y: cy + ry * 0.66),
               controlPoint2: NSPoint(x: cx - rx * 0.62, y: cy + ry))
    body.close()

    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    skin.draw(in: body.bounds.insetBy(dx: -size * 0.1, dy: -size * 0.1), angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // Highlight shaped like an open book's gutter — two leaves meeting at a spine.
    let gutter = NSBezierPath()
    let gx = cx - size * 0.055, gTop = cy + size * 0.115, gBottom = cy - size * 0.115
    gutter.move(to: NSPoint(x: gx, y: gTop))
    gutter.curve(to: NSPoint(x: gx - size * 0.125, y: gBottom + size * 0.028),
                 controlPoint1: NSPoint(x: gx - size * 0.085, y: gTop - size * 0.010),
                 controlPoint2: NSPoint(x: gx - size * 0.128, y: gTop - size * 0.098))
    gutter.line(to: NSPoint(x: gx, y: gBottom))
    gutter.close()
    let gutter2 = NSBezierPath()
    gutter2.move(to: NSPoint(x: gx + size * 0.008, y: gTop))
    gutter2.curve(to: NSPoint(x: gx + size * 0.140, y: gBottom + size * 0.028),
                  controlPoint1: NSPoint(x: gx + size * 0.095, y: gTop - size * 0.010),
                  controlPoint2: NSPoint(x: gx + size * 0.143, y: gTop - size * 0.098))
    gutter2.line(to: NSPoint(x: gx + size * 0.008, y: gBottom))
    gutter2.close()
    NSColor(white: 1, alpha: variant == .tinted ? 0.30 : 0.88).setFill()
    gutter.fill()
    gutter2.fill()

    // Stem and leaf.
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: cx - size * 0.03, y: cy + ry * 0.97))
    stem.line(to: NSPoint(x: cx - size * 0.012, y: cy + ry * 1.13))
    stem.lineWidth = size * 0.022
    stem.lineCapStyle = .round
    (variant == .tinted ? NSColor(white: 0.8, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.28, blue: 0.13, alpha: 1)).setStroke()
    stem.stroke()

    let leaf = NSBezierPath()
    let lx = cx + size * 0.012, ly = cy + ry * 1.10
    leaf.move(to: NSPoint(x: lx, y: ly))
    leaf.curve(to: NSPoint(x: lx + size * 0.150, y: ly + size * 0.058),
               controlPoint1: NSPoint(x: lx + size * 0.052, y: ly + size * 0.062),
               controlPoint2: NSPoint(x: lx + size * 0.112, y: ly + size * 0.082))
    leaf.curve(to: NSPoint(x: lx, y: ly),
               controlPoint1: NSPoint(x: lx + size * 0.112, y: ly + size * 0.012),
               controlPoint2: NSPoint(x: lx + size * 0.052, y: ly - size * 0.008))
    leaf.close()
    leafColor.setFill()
    leaf.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let image = cgContext.makeImage() else { fatalError("image") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let base = (output as NSString).deletingPathExtension
render(.light, to: output)
render(.dark, to: base + "-Dark.png")
render(.tinted, to: base + "-Tinted.png")

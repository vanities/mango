// Renders numbered comic pages (and a PDF) so the app has something real to open.
//   swift scripts/render-pages.swift <outDir> <count> <label> [--wide N] [--pdf out.pdf]
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let pdfPath = flag("--pdf")
let widePage = flag("--wide").flatMap(Int.init)
guard args.count >= 3 else { fatalError("usage: <outDir> <count> <label>") }
let outDir = args[0]
let count = Int(args[1]) ?? 8
let label = args[2]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let hue = CGFloat(abs(label.hashValue % 360)) / 360.0

func drawPage(_ number: Int, size: CGSize, into context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let canvas = NSRect(origin: .zero, size: size)

    NSColor(calibratedHue: hue, saturation: 0.10, brightness: 0.97, alpha: 1).setFill()
    canvas.fill()

    // Panel grid, so a page looks like a page at thumbnail size.
    let inset = size.width * 0.06
    let gutter = size.width * 0.03
    let isWide = size.width > size.height
    let columns = isWide ? 4 : 2
    let rows = 3
    let cellW = (size.width - inset * 2 - gutter * CGFloat(columns - 1)) / CGFloat(columns)
    let cellH = (size.height - inset * 2 - gutter * CGFloat(rows - 1) - size.height * 0.08) / CGFloat(rows)
    for row in 0..<rows {
        for column in 0..<columns {
            let rect = NSRect(x: inset + CGFloat(column) * (cellW + gutter),
                              y: inset + CGFloat(row) * (cellH + gutter),
                              width: cellW, height: cellH)
            NSColor(calibratedHue: hue, saturation: 0.28, brightness: 0.82 - CGFloat(row) * 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            NSColor(white: 0.15, alpha: 0.65).setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            border.lineWidth = 3
            border.stroke()
        }
    }

    let title = "\(label) — page \(number)\(isWide ? "  (spread)" : "")"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: size.height * 0.035),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
    let string = NSAttributedString(string: title, attributes: attributes)
    let textSize = string.size()
    string.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: size.height - inset - textSize.height))

    let big = NSAttributedString(string: "\(number)", attributes: [
        .font: NSFont.boldSystemFont(ofSize: size.height * 0.16),
        .foregroundColor: NSColor(white: 0.10, alpha: 0.22),
    ])
    let bigSize = big.size()
    big.draw(at: NSPoint(x: (size.width - bigSize.width) / 2, y: (size.height - bigSize.height) / 2))

    NSGraphicsContext.restoreGraphicsState()
}

func pageSize(_ number: Int) -> CGSize {
    number == widePage ? CGSize(width: 1600, height: 1200) : CGSize(width: 800, height: 1200)
}

if let pdfPath {
    var mediaBox = CGRect(origin: .zero, size: pageSize(1))
    guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: pdfPath) as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { fatalError("pdf context") }
    for number in 1...count {
        var box = CGRect(origin: .zero, size: pageSize(number))
        context.beginPage(mediaBox: &box)
        drawPage(number, size: box.size, into: context)
        context.endPage()
    }
    context.closePDF()
    print("wrote \(pdfPath) (\(count) pages)")
} else {
    for number in 1...count {
        let size = pageSize(number)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { fatalError("context") }
        drawPage(number, size: size, into: context)
        guard let image = context.makeImage() else { fatalError("image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { fatalError("jpeg") }
        let path = "\(outDir)/\(String(format: "%03d", number)).jpg"
        try! data.write(to: URL(fileURLWithPath: path))
    }
    print("wrote \(count) pages to \(outDir)")
}

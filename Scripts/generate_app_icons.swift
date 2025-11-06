import AppKit

let accent = NSColor(calibratedRed: 0.321, green: 0.639, blue: 0.482, alpha: 1.0)
let accentSoft = NSColor(calibratedRed: 0.321, green: 0.639, blue: 0.482, alpha: 0.35)

struct Output {
    let filename: String
    let size: CGFloat
}

let outputs: [Output] = [
    Output(filename: "Icon-20@2x.png", size: 40),
    Output(filename: "Icon-20@3x.png", size: 60),
    Output(filename: "Icon-29@2x.png", size: 58),
    Output(filename: "Icon-29@3x.png", size: 87),
    Output(filename: "Icon-40@2x.png", size: 80),
    Output(filename: "Icon-40@3x.png", size: 120),
    Output(filename: "Icon-60@2x.png", size: 120),
    Output(filename: "Icon-60@3x.png", size: 180),
    Output(filename: "Icon-20iPad@2x.png", size: 40),
    Output(filename: "Icon-29iPad@2x.png", size: 58),
    Output(filename: "Icon-40iPad@2x.png", size: 80),
    Output(filename: "Icon-76@1x.png", size: 76),
    Output(filename: "Icon-76@2x.png", size: 152),
    Output(filename: "Icon-83_5@2x.png", size: 167),
    Output(filename: "Icon-1024.png", size: 1024)
]

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_app_icons.swift <output-directory>\n", stderr)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Unable to get graphics context")
    }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let scale = size / 256.0

    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let backgroundPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 256, height: 256),
                                cornerWidth: 52,
                                cornerHeight: 52,
                                transform: nil)
    context.addPath(backgroundPath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()

    let knobPath = CGPath(roundedRect: CGRect(x: 112, y: 30, width: 32, height: 22),
                          cornerWidth: 11,
                          cornerHeight: 11,
                          transform: nil)
    context.addPath(knobPath)
    context.setFillColor(accent.cgColor)
    context.fillPath()

    let outerRingRect = CGRect(x: 128 - 90, y: 144 - 90, width: 180, height: 180)
    context.setStrokeColor(accent.cgColor)
    context.setLineWidth(20)
    context.strokeEllipse(in: outerRingRect)

    context.saveGState()
    context.setStrokeColor(accentSoft.cgColor)
    context.setLineWidth(18)
    context.beginPath()
    context.addArc(center: CGPoint(x: 128, y: 144),
                   radius: 90,
                   startAngle: CGFloat(22.0 * .pi / 180.0),
                   endAngle: CGFloat(320.0 * .pi / 180.0),
                   clockwise: false)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setStrokeColor(accent.cgColor)
    context.setLineWidth(14)
    context.beginPath()
    context.addArc(center: CGPoint(x: 128, y: 144),
                   radius: 76,
                   startAngle: CGFloat(200.0 * .pi / 180.0),
                   endAngle: CGFloat(110.0 * .pi / 180.0),
                   clockwise: true)
    context.strokePath()
    context.restoreGState()

    let forkLeft = CGPath(roundedRect: CGRect(x: 108, y: 100, width: 10, height: 60),
                          cornerWidth: 4,
                          cornerHeight: 4,
                          transform: nil)
    let forkRight = CGPath(roundedRect: CGRect(x: 122, y: 100, width: 10, height: 60),
                           cornerWidth: 4,
                           cornerHeight: 4,
                           transform: nil)
    context.addPath(forkLeft)
    context.addPath(forkRight)
    context.setFillColor(accent.cgColor)
    context.fillPath()

    let spoonOuter = CGPath(roundedRect: CGRect(x: 142, y: 102, width: 28, height: 58),
                            cornerWidth: 14,
                            cornerHeight: 14,
                            transform: nil)
    context.addPath(spoonOuter)
    context.setFillColor(accent.cgColor)
    context.fillPath()

    let spoonInner = CGPath(roundedRect: CGRect(x: 150, y: 112, width: 12, height: 38),
                            cornerWidth: 6,
                            cornerHeight: 6,
                            transform: nil)
    context.addPath(spoonInner)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()

    context.restoreGState()

    return image
}

for output in outputs {
    let image = drawIcon(size: output.size)
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to create PNG data for \(output.filename)")
    }
    let destination = outputDirectory.appendingPathComponent(output.filename)
    do {
        try pngData.write(to: destination)
    } catch {
        fatalError("Failed to write \(output.filename): \(error)")
    }
}

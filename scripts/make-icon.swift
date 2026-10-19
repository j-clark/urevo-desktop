import AppKit

// Draw the app's mark at each native icon size; no bitmap source or dependency.
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func drawMark() {
    let background = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 216, yRadius: 216)
    NSColor(calibratedRed: 0.065, green: 0.083, blue: 0.081, alpha: 1).setFill()
    background.fill()
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.21, blue: 0.18, alpha: 1),
               ending: NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.065, alpha: 1))!.draw(in: background, angle: -90)

    let green = NSColor(calibratedRed: 0.68, green: 0.94, blue: 0.42, alpha: 1)
    green.withAlphaComponent(0.22).setStroke()
    let track = NSBezierPath(roundedRect: NSRect(x: 190, y: 170, width: 644, height: 130), xRadius: 65, yRadius: 65)
    track.lineWidth = 20
    track.stroke()

    green.setFill()
    NSBezierPath(ovalIn: NSRect(x: 540, y: 697, width: 112, height: 112)).fill()
    green.setStroke()
    func stroke(_ points: [NSPoint], width: CGFloat) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = width
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.stroke()
    }
    // Forward-leaning stride, two arms and two legs, above the walking belt.
    stroke([NSPoint(x: 558, y: 637), NSPoint(x: 486, y: 474), NSPoint(x: 606, y: 374), NSPoint(x: 644, y: 266)], width: 66)
    stroke([NSPoint(x: 486, y: 474), NSPoint(x: 424, y: 343), NSPoint(x: 317, y: 268)], width: 66)
    stroke([NSPoint(x: 550, y: 624), NSPoint(x: 620, y: 535), NSPoint(x: 728, y: 535)], width: 48)
    stroke([NSPoint(x: 545, y: 626), NSPoint(x: 434, y: 594), NSPoint(x: 362, y: 511)], width: 48)
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawMark()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let url = URL(fileURLWithPath: destination).appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

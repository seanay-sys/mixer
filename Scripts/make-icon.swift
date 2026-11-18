// Draws the app icon PNG at 1024x1024: three mixer faders on a rounded tile.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.27, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.13, alpha: 1)])!
        .draw(in: path, angle: -90)

    let levels: [CGFloat] = [0.62, 0.35, 0.8]
    let colors = [NSColor.systemTeal, NSColor.systemIndigo, NSColor.systemOrange]
    for (i, level) in levels.enumerated() {
        let x = 300 + CGFloat(i) * 212
        let bottom: CGFloat = 250, top: CGFloat = 774
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 18, y: bottom, width: 36, height: top - bottom), xRadius: 18, yRadius: 18).fill()
        let knobY = bottom + (top - bottom) * level
        colors[i].setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 18, y: bottom, width: 36, height: knobY - bottom), xRadius: 18, yRadius: 18).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 62, y: knobY - 30, width: 124, height: 60), xRadius: 30, yRadius: 30).fill()
    }
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

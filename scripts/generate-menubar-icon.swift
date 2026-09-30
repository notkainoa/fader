// Renders the menu bar status icon: the three-fader mark as an Apple
// template image (monochrome, alpha-only; the system tints it per theme).
// Outputs MenuBarIconTemplate.png (18pt) and @2x. Regenerate via
// `swift scripts/generate-menubar-icon.swift Sliders/Resources`.
import AppKit

let point: CGFloat = 18
/// Knob travel fractions match the app icon and the site mockup.
let faders: [(x: CGFloat, knob: CGFloat)] = [
    (3.5, 0.30),
    (9, 0.72),
    (14.5, 0.48),
]

func render(scale: CGFloat) -> Data {
    let pixels = Int(point * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Failed to create bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let trackWidth: CGFloat = 1.5
    let trackTop: CGFloat = 16.5
    let trackBottom: CGFloat = 1.5
    let knobRadius: CGFloat = 2.5

    for fader in faders {
        let knobCenterY = trackBottom + (trackTop - trackBottom) * fader.knob

        // Above the knob: faint remainder of the track.
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: fader.x - trackWidth / 2, y: knobCenterY,
                                width: trackWidth, height: trackTop - knobCenterY),
            xRadius: trackWidth / 2, yRadius: trackWidth / 2
        ).fill()

        // Below the knob: the filled part.
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: fader.x - trackWidth / 2, y: trackBottom,
                                width: trackWidth, height: knobCenterY - trackBottom),
            xRadius: trackWidth / 2, yRadius: trackWidth / 2
        ).fill()

        NSBezierPath(ovalIn: NSRect(
            x: fader.x - knobRadius, y: knobCenterY - knobRadius,
            width: knobRadius * 2, height: knobRadius * 2
        )).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    return png
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
do {
    try render(scale: 1).write(to: URL(fileURLWithPath: "\(outputDir)/MenuBarIconTemplate.png"))
    try render(scale: 2).write(to: URL(fileURLWithPath: "\(outputDir)/MenuBarIconTemplate@2x.png"))
} catch {
    fatalError("Failed to write icons: \(error)")
}

print("Wrote MenuBarIconTemplate.png and @2x to \(outputDir)")

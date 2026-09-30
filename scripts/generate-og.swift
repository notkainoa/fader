// Renders the Open Graph preview card (1200x630) for link unfurls.
// Regenerate with `make og` after changing the drawing.
import AppKit

let width: CGFloat = 1200
let height: CGFloat = 630
let image = NSImage(size: NSSize(width: width, height: height))

image.lockFocus()

// Background matching the site: pure black with a soft blue glow.
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
let glow = NSGradient(
    starting: NSColor(red: 0.16, green: 0.59, blue: 1.0, alpha: 0.16),
    ending: NSColor(red: 0.16, green: 0.59, blue: 1.0, alpha: 0)
)!
glow.draw(
    fromCenter: NSPoint(x: width * 0.55, y: height * 0.62), radius: 0,
    toCenter: NSPoint(x: width * 0.55, y: height * 0.62), radius: 520,
    options: []
)

// Sliders motif on the left.
let trackWidth: CGFloat = 26
let trackHeight: CGFloat = 360
let trackY = (height - trackHeight) / 2
let knobRadius: CGFloat = 56
let positions: [(x: CGFloat, knob: CGFloat)] = [
    (170, 0.30),
    (300, 0.72),
    (430, 0.48),
]

for fader in positions {
    let track = NSBezierPath(
        roundedRect: NSRect(x: fader.x - trackWidth / 2, y: trackY, width: trackWidth, height: trackHeight),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(white: 1, alpha: 0.14).setFill()
    track.fill()

    let knobCenterY = trackY + trackHeight * fader.knob
    let fill = NSBezierPath(
        roundedRect: NSRect(
            x: fader.x - trackWidth / 2,
            y: trackY,
            width: trackWidth,
            height: knobCenterY - trackY
        ),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(red: 0.36, green: 0.61, blue: 1.0, alpha: 1).setFill()
    fill.fill()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: fader.x - knobRadius,
        y: knobCenterY - knobRadius,
        width: knobRadius * 2,
        height: knobRadius * 2
    )).fill()
    NSShadow().set()
}

/// Wordmark and tagline on the right, in the site's Apple-style palette.
let title = NSAttributedString(string: "Sliders", attributes: [
    .font: NSFont.systemFont(ofSize: 110, weight: .bold),
    .foregroundColor: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1),
    .kern: -2.2,
])
title.draw(at: NSPoint(x: 560, y: 330))

let tagline = NSAttributedString(
    string: "Per-app volume. Two outputs at once.\nOne-click switching in your menu bar.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 38, weight: .regular),
        .foregroundColor: NSColor(red: 0.525, green: 0.525, blue: 0.545, alpha: 1),
    ]
)
tagline.draw(at: NSPoint(x: 564, y: 200))

let badge = NSAttributedString(
    string: "free · open source · no telemetry",
    attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .medium),
        .foregroundColor: NSColor(red: 0.16, green: 0.59, blue: 1.0, alpha: 1),
    ]
)
badge.draw(at: NSPoint(x: 564, y: 120))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render OG image")
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og.png")
do {
    try png.write(to: output)
} catch {
    fatalError("Failed to write \(output.path): \(error)")
}

print("Wrote \(output.path)")

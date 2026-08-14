// Renders the OnAir app icon — an ON AIR studio sign on the macOS icon grid — at every size an
// icns wants, as PNGs into the directory given as the first argument. `make-icon.sh` packs them
// with `iconutil`. Pure code, no design tool: rerunning it is the way the icon is ever edited.
//
// Build-host tool only. It is not a member of any SwiftPM target, so importing AppKit here does
// not touch invariant A2 (kits stay UI-framework-free).

import AppKit

let brandRed = NSColor(srgbRed: 0xA0 / 255, green: 0x1D / 255, blue: 0x21 / 255, alpha: 1)
let glowRed = NSColor(srgbRed: 0xD0 / 255, green: 0x20 / 255, blue: 0x26 / 255, alpha: 1)
let letterRed = NSColor(srgbRed: 1.0, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
let plateTop = NSColor(srgbRed: 0x2A / 255, green: 0x2D / 255, blue: 0x33 / 255, alpha: 1)
let plateBottom = NSColor(srgbRed: 0x15 / 255, green: 0x17 / 255, blue: 0x1B / 255, alpha: 1)

/// Draw the icon into a fresh bitmap of `pixels` × `pixels`. Every metric is a fraction of the
/// 1024-point Apple icon grid, so all ten sizes are the same drawing, not resamples of one PNG.
func render(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate a \(pixels)px bitmap") }

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        // Without this guard a nil context makes every draw call a no-op and the lane would
        // pack ten fully transparent PNGs into a structurally valid icns.
        fatalError("could not create a drawing context for \(pixels)px")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context

    let s = CGFloat(pixels) / 1024.0
    func u(_ points: CGFloat) -> CGFloat { points * s }

    // The plate: Apple's icon grid is an 824×824 rounded rect centred on a 1024 canvas,
    // corner radius ≈ 185. Everything outside it stays transparent.
    let plateRect = NSRect(x: u(100), y: u(100), width: u(824), height: u(824))
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: u(185), yRadius: u(185))
    NSGradient(starting: plateTop, ending: plateBottom)?.draw(in: plate, angle: -90)

    // The sign's frame: a thin red bezel inset from the plate edge.
    let frameRect = plateRect.insetBy(dx: u(58), dy: u(58))
    let frame = NSBezierPath(roundedRect: frameRect, xRadius: u(130), yRadius: u(130))
    frame.lineWidth = u(14)
    brandRed.withAlphaComponent(0.9).setStroke()
    frame.stroke()

    // "ON AIR", SF Rounded, sized to fit the frame's width with margin to spare. The face is
    // resolved loudly: a silent fall-back to plain SF would change the committed icns without
    // anyone choosing it.
    let text = "ON AIR" as NSString
    guard let descriptor = NSFont.systemFont(ofSize: u(200), weight: .heavy)
        .fontDescriptor.withDesign(.rounded)
    else { fatalError("SF Rounded is unavailable on this machine") }
    func signFont(_ size: CGFloat) -> NSFont {
        guard let font = NSFont(descriptor: descriptor, size: size) else {
            fatalError("could not instantiate SF Rounded at \(size)pt")
        }
        return font
    }
    var fontSize = u(200)
    var attributes: [NSAttributedString.Key: Any] = [.kern: u(10)]
    let maxWidth = frameRect.width - u(120)
    while fontSize > u(10) {
        attributes[.font] = signFont(fontSize)
        if text.size(withAttributes: attributes).width <= maxWidth { break }
        fontSize -= u(4)
    }

    // Glow first — the same string stamped through a heavy blur, twice so it accumulates —
    // then the bright letters on top. That is the whole neon effect.
    let size = text.size(withAttributes: attributes)
    // The u(8) lift is optical centring: the measured box reserves descender space that no
    // capital letter uses, so true-centre reads slightly low.
    let origin = NSPoint(x: (CGFloat(pixels) - size.width) / 2,
                         y: (CGFloat(pixels) - size.height) / 2 + u(8))
    let glow = NSShadow()
    glow.shadowColor = glowRed
    glow.shadowBlurRadius = u(48)
    glow.shadowOffset = .zero
    for _ in 0 ..< 2 {
        var glowAttributes = attributes
        glowAttributes[.foregroundColor] = glowRed
        glowAttributes[.shadow] = glow
        text.draw(at: origin, withAttributes: glowAttributes)
    }
    var faceAttributes = attributes
    faceAttributes[.foregroundColor] = letterRed
    text.draw(at: origin, withAttributes: faceAttributes)

    return rep
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <iconset-dir>\n".utf8))
    exit(64)
}
let iconset = URL(fileURLWithPath: arguments[1], isDirectory: true)

// The ten members of a .iconset: five point sizes, each at 1x and 2x.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = render(pixels: points * scale)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not encode \(points)pt@\(scale)x as PNG")
        }
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try png.write(to: file)
    }
}

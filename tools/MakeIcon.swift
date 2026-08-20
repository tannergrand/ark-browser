// Generates Ark's app icon. Kept in the repo so the icon is reproducible
// rather than a mystery binary: `swift tools/MakeIcon.swift`.
//
// Draws at 1024 and lets `sips` downsample, following Apple's macOS grid —
// the art sits inset inside the canvas rather than filling it edge to edge.
import AppKit

let canvas: CGFloat = 1024
let inset: CGFloat = 86
let side = canvas - inset * 2
let radius: CGFloat = 196   // approximates the macOS squircle at this size

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

let art = NSRect(x: inset, y: inset, width: side, height: side)
let squircle = NSBezierPath(roundedRect: art, xRadius: radius, yRadius: radius)

// --- Ambient shadow beneath the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18),
              blur: 44,
              color: hex(0x000000, 0.42).cgColor)
hex(0x1B1B3A).setFill()
squircle.fill()
ctx.restoreGState()

// --- Body gradient: deep indigo into cyan, the app's accent range
ctx.saveGState()
squircle.setClip()
let body = NSGradient(colors: [hex(0x1E1B4B), hex(0x4338CA), hex(0x0EA5E9), hex(0x22D3EE)],
                      atLocations: [0.0, 0.42, 0.80, 1.0],
                      colorSpace: .sRGB)!
body.draw(in: art, angle: -55)

// Vignette so the edges read as glass rather than flat paint
let vignette = NSGradient(colors: [hex(0x000000, 0.0), hex(0x000000, 0.30)],
                          atLocations: [0.45, 1.0], colorSpace: .sRGB)!
vignette.draw(in: art, relativeCenterPosition: NSPoint(x: -0.25, y: 0.35))

// --- A simplified ark: hull, cabin, and a waterline. Two curves and three
// rectangles, no detail — at 32pt in the Dock, anything finer turns to mud, and
// the silhouette is what has to read.
func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}

let hullTop = art.midY - side * 0.06
let hullDepth = side * 0.20
let hullLeft = art.minX + side * 0.16
let hullRight = art.maxX - side * 0.16

// Hull: a flat deck with a curved bottom, tapered at both ends.
let hull = NSBezierPath()
hull.move(to: NSPoint(x: hullLeft, y: hullTop))
hull.curve(to: NSPoint(x: hullRight, y: hullTop),
           controlPoint1: NSPoint(x: art.midX - side * 0.10, y: hullTop - hullDepth * 1.5),
           controlPoint2: NSPoint(x: art.midX + side * 0.10, y: hullTop - hullDepth * 1.5))
hull.close()
fill(hull, hex(0xFFFFFF, 0.95))

// Cabin: one box, plus a shorter one stacked on top. Centred slightly aft.
let cabinWidth = side * 0.40
let cabinHeight = side * 0.14
let cabinX = art.midX - cabinWidth * 0.52
let cabin = NSBezierPath(roundedRect:
    NSRect(x: cabinX, y: hullTop, width: cabinWidth, height: cabinHeight),
    xRadius: side * 0.018, yRadius: side * 0.018)
fill(cabin, hex(0xFFFFFF, 0.95))

let roofWidth = cabinWidth * 0.62
let roof = NSBezierPath(roundedRect:
    NSRect(x: art.midX - roofWidth * 0.52, y: hullTop + cabinHeight,
           width: roofWidth, height: cabinHeight * 0.62),
    xRadius: side * 0.016, yRadius: side * 0.016)
fill(roof, hex(0xFFFFFF, 0.95))

// Waterline: two strokes under the hull, the far one dimmer. Reads as water
// without drawing waves.
func waterline(y: CGFloat, inset: CGFloat, alpha: CGFloat, width: CGFloat) {
    let line = NSBezierPath()
    let left = art.minX + side * inset
    let right = art.maxX - side * inset
    line.move(to: NSPoint(x: left, y: y))
    line.curve(to: NSPoint(x: right, y: y),
               controlPoint1: NSPoint(x: art.midX - side * 0.12, y: y + side * 0.045),
               controlPoint2: NSPoint(x: art.midX + side * 0.12, y: y - side * 0.045))
    line.lineWidth = width
    line.lineCapStyle = .round
    hex(0xFFFFFF, alpha).setStroke()
    line.stroke()
}
waterline(y: hullTop - hullDepth - side * 0.045, inset: 0.11, alpha: 0.85, width: side * 0.032)
waterline(y: hullTop - hullDepth - side * 0.115, inset: 0.19, alpha: 0.42, width: side * 0.026)

// --- Specular bloom, upper-left. Radial and fully faded at its edge, so there
// is no clip boundary to catch the eye.
let bloom = NSGradient(colors: [hex(0xFFFFFF, 0.40), hex(0xFFFFFF, 0.10), hex(0xFFFFFF, 0.0)],
                       atLocations: [0.0, 0.45, 1.0], colorSpace: .sRGB)!
bloom.draw(in: art.insetBy(dx: -side * 0.15, dy: -side * 0.15),
           relativeCenterPosition: NSPoint(x: -0.45, y: 0.55))

ctx.restoreGState()

// --- Bright edge along the top, fading toward the sides
ctx.saveGState()
let topEdge = NSBezierPath(roundedRect: art.insetBy(dx: 5, dy: 5),
                           xRadius: radius - 5, yRadius: radius - 5)
topEdge.lineWidth = 9
topEdge.setClip()
NSGradient(colors: [hex(0xFFFFFF, 0.62), hex(0xFFFFFF, 0.0)],
           atLocations: [0.0, 0.55], colorSpace: .sRGB)!
    .draw(in: NSRect(x: art.minX, y: art.midY, width: art.width, height: art.height / 2),
          angle: -90)
ctx.restoreGState()

ctx.restoreGState()
ctx.saveGState()

// --- Rim light, matching the app's glassRim gradient
let rim = NSBezierPath(roundedRect: art.insetBy(dx: 3, dy: 3),
                       xRadius: radius - 3, yRadius: radius - 3)
rim.lineWidth = 6
hex(0xFFFFFF, 0.30).setStroke()
rim.stroke()

let innerRim = NSBezierPath(roundedRect: art.insetBy(dx: 9, dy: 9),
                            xRadius: radius - 9, yRadius: radius - 9)
innerRim.lineWidth = 2
hex(0xFFFFFF, 0.10).setStroke()
innerRim.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: "tools/icon-1024.png")
try! png.write(to: out)
print("wrote \(out.path)")

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
hex(0x0A0C11).setFill()
squircle.fill()
ctx.restoreGState()

// --- Body: near-black, with just enough gradient to avoid looking like a flat
// swatch. The old indigo-to-cyan wash was the loudest thing on the Dock; a dark
// tile lets the mark be the only thing you read.
ctx.saveGState()
squircle.setClip()
let body = NSGradient(colors: [hex(0x161A22), hex(0x0D1016), hex(0x090B0F)],
                      atLocations: [0.0, 0.55, 1.0],
                      colorSpace: .sRGB)!
body.draw(in: art, angle: -78)

// One cool highlight behind the mark, very faint. Depth without colour.
NSGradient(colors: [hex(0x2E5A7A, 0.30), hex(0x2E5A7A, 0.0)],
           atLocations: [0.0, 1.0], colorSpace: .sRGB)!
    .draw(in: art.insetBy(dx: side * 0.06, dy: side * 0.06),
          relativeCenterPosition: NSPoint(x: 0, y: 0.12))

// --- The mark: one hull, one cabin, one waterline. Centred as a *group* rather
// than individually — centring the hull alone leaves the whole thing looking
// low, because the cabin sits above it and carries visual weight.
//
// Simplified from the earlier version, which had a stacked roof and two
// waterlines. At 32pt in the Dock those extra strokes closed up into a smudge.
func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}

// Proportions tuned by rendering at 64pt and looking: at that size a deep hull
// and a wide cabin merge into one blob that reads like an arrow. A shallower,
// wider hull with a narrower cabin keeps the boat silhouette legible.
let markWidth = side * 0.66
let hullDepth = side * 0.155
let cabinHeight = side * 0.145
let waterGap = side * 0.075
let waterWeight = side * 0.034

// Total height of hull + cabin + waterline, so the group can be centred.
let markHeight = cabinHeight + hullDepth + waterGap + waterWeight
let groupBottom = art.midY - markHeight / 2
let waterY = groupBottom + waterWeight / 2
let hullBottom = waterY + waterGap
let deckY = hullBottom + hullDepth

let hullLeft = art.midX - markWidth / 2
let hullRight = art.midX + markWidth / 2

// Hull: flat deck, curved bottom, tapered ends.
let hull = NSBezierPath()
hull.move(to: NSPoint(x: hullLeft, y: deckY))
hull.curve(to: NSPoint(x: hullRight, y: deckY),
           controlPoint1: NSPoint(x: art.midX - markWidth * 0.26, y: hullBottom - hullDepth * 0.75),
           controlPoint2: NSPoint(x: art.midX + markWidth * 0.26, y: hullBottom - hullDepth * 0.75))
hull.close()
fill(hull, hex(0xFFFFFF, 0.96))

// Cabin: one block, centred.
let cabinWidth = markWidth * 0.34
let cabin = NSBezierPath(roundedRect:
    NSRect(x: art.midX - cabinWidth / 2, y: deckY,
           width: cabinWidth, height: cabinHeight),
    xRadius: side * 0.02, yRadius: side * 0.02)
fill(cabin, hex(0xFFFFFF, 0.96))

// Waterline: one stroke, narrower than the hull so the hull reads as sitting in
// it rather than on it.
let water = NSBezierPath()
let waterInset = markWidth * 0.06
water.move(to: NSPoint(x: hullLeft - waterInset, y: waterY))
water.curve(to: NSPoint(x: hullRight + waterInset, y: waterY),
            controlPoint1: NSPoint(x: art.midX - markWidth * 0.22, y: waterY + side * 0.035),
            controlPoint2: NSPoint(x: art.midX + markWidth * 0.22, y: waterY - side * 0.035))
water.lineWidth = waterWeight
water.lineCapStyle = .round
hex(0xFFFFFF, 0.68).setStroke()
water.stroke()

ctx.restoreGState()

// --- Bright edge along the top, fading toward the sides
ctx.saveGState()
let topEdge = NSBezierPath(roundedRect: art.insetBy(dx: 5, dy: 5),
                           xRadius: radius - 5, yRadius: radius - 5)
topEdge.lineWidth = 9
topEdge.setClip()
NSGradient(colors: [hex(0xFFFFFF, 0.30), hex(0xFFFFFF, 0.0)],
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
hex(0xFFFFFF, 0.16).setStroke()
rim.stroke()

let innerRim = NSBezierPath(roundedRect: art.insetBy(dx: 9, dy: 9),
                            xRadius: radius - 9, yRadius: radius - 9)
innerRim.lineWidth = 2
hex(0xFFFFFF, 0.06).setStroke()
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

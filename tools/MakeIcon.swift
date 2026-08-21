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

// --- Body: a saturated gradient tile, the way Arc's is. All the colour lives
// here so the mark can stay a single flat shape — the previous near-black tile
// forced the mark to carry both the colour and the meaning.
ctx.saveGState()
squircle.setClip()
let body = NSGradient(colors: [hex(0x6B5BFF), hex(0x4028C9), hex(0x1B1252)],
                      atLocations: [0.0, 0.55, 1.0],
                      colorSpace: .sRGB)!
body.draw(in: art, angle: -78)

// Three radial washes over the base, mesh-gradient style. Each carries a mid
// stop at a quarter strength: a plain colour-to-clear ramp spreads across the
// whole tile and turns the indigo into flat dusty pink, because NSGradient
// sizes a radial to reach the corners of the rect it is drawn in.
let wash = art.insetBy(dx: -side * 0.1, dy: -side * 0.1)
func bloom(_ color: UInt32, _ alpha: CGFloat, x: CGFloat, y: CGFloat) {
    NSGradient(colors: [hex(color, alpha), hex(color, alpha * 0.22), hex(color, 0)],
               atLocations: [0.0, 0.42, 0.78], colorSpace: .sRGB)!
        .draw(in: wash, relativeCenterPosition: NSPoint(x: x, y: y))
}
bloom(0xFF6B5E, 0.85, x:  0.86, y: -0.92)   // coral, bottom right
bloom(0xFFB05E, 0.55, x: -0.88, y:  0.90)   // amber, top left
bloom(0xB07BFF, 0.45, x:  0.90, y:  0.86)   // violet, top right

// --- The mark: one open ring. The boat is gone on purpose — Arc's mark is pure
// geometry, and at 32pt in the Dock a hull, a cabin and a waterline collapsed
// into a smudge no matter how they were proportioned. A single stroke does not.
//
// The opening sits at the bottom, centred, so it reads as a hatch rather than
// as a letter C tipped on its side. 80° of gap: any narrower and the round caps
// close it up at small sizes, any wider and the ring stops reading as a ring.
//
// Radius and weight are traded against each other rather than set independently:
// at 16pt the inner counter is about four pixels across, and a heavier stroke
// fills it in, at which point the ring reads as a solid blob.
let ringRadius = side * 0.245
let gap: CGFloat = 80
let ring = NSBezierPath()
ring.appendArc(withCenter: NSPoint(x: art.midX, y: art.midY),
               radius: ringRadius,
               startAngle: -90 + gap / 2,
               endAngle: -90 - gap / 2 + 360,
               clockwise: false)
ring.lineWidth = side * 0.106
ring.lineCapStyle = .round
hex(0xFFFFFF, 0.96).setStroke()
ring.stroke()

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

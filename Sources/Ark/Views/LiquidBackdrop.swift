import SwiftUI

/// A soft field of blurred colour, used behind the new-tab command bar and on
/// blank tabs.
///
/// Deterministic from a seed, deliberately: a random field regenerated on every
/// body evaluation would shimmer as you type. Seeding also means the same new
/// tab keeps the same backdrop for its lifetime.
///
/// Motion, done the cheap way. `Motion.swift` says nothing repeats, and this is
/// the one exception — so it earns it by never re-rendering the blur. The field
/// is flattened to a single texture with `.drawingGroup()` *first*, and only
/// then transformed: a slow counter-rotation, a scale breathe, and a drift.
/// Those are GPU transforms on an existing texture, so the expensive blur is
/// still paid exactly once. Animating blob positions instead would re-blur
/// every frame, which is the thing to avoid.
///
/// Under Reduce Motion it holds still. The layer only exists while a new tab or
/// the command bar is on screen, so idle chrome still costs nothing.
struct LiquidBackdrop: View {
    let seed: Int
    /// Dims the whole field, for use behind a floating panel.
    var dimming: Double = 0.28

    /// Curated palettes, so the result is always harmonious rather than
    /// arbitrary. Each is a deep base plus two or three lighter accents.
    private static let palettes: [[Color]] = [
        [Color(red: 0.10, green: 0.09, blue: 0.28), Color(red: 0.35, green: 0.24, blue: 0.78),
         Color(red: 0.05, green: 0.62, blue: 0.78), Color(red: 0.16, green: 0.82, blue: 0.72)],
        [Color(red: 0.16, green: 0.05, blue: 0.20), Color(red: 0.72, green: 0.18, blue: 0.44),
         Color(red: 0.95, green: 0.45, blue: 0.35), Color(red: 0.99, green: 0.72, blue: 0.42)],
        [Color(red: 0.04, green: 0.15, blue: 0.16), Color(red: 0.06, green: 0.45, blue: 0.44),
         Color(red: 0.35, green: 0.78, blue: 0.60), Color(red: 0.85, green: 0.92, blue: 0.62)],
        [Color(red: 0.09, green: 0.11, blue: 0.22), Color(red: 0.24, green: 0.36, blue: 0.72),
         Color(red: 0.55, green: 0.62, blue: 0.95), Color(red: 0.88, green: 0.72, blue: 0.98)],
        [Color(red: 0.18, green: 0.08, blue: 0.06), Color(red: 0.62, green: 0.24, blue: 0.14),
         Color(red: 0.92, green: 0.55, blue: 0.24), Color(red: 0.98, green: 0.84, blue: 0.55)],
        [Color(red: 0.06, green: 0.13, blue: 0.25), Color(red: 0.13, green: 0.42, blue: 0.62),
         Color(red: 0.42, green: 0.72, blue: 0.85), Color(red: 0.78, green: 0.92, blue: 0.95)]
    ]

    /// Small deterministic PRNG. Foundation's is fine but this keeps the field
    /// reproducible from an integer without threading a generator around.
    private struct Rand {
        var state: UInt64
        init(_ seed: Int) { state = UInt64(bitPattern: Int64(seed)) | 1 }
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        mutating func inRange(_ lower: Double, _ upper: Double) -> Double {
            lower + next() * (upper - lower)
        }
    }

    private struct Blob: Identifiable {
        let id: Int
        let color: Color
        let unitX: Double
        let unitY: Double
        let scale: Double
    }

    private var palette: [Color] {
        Self.palette(seed: seed)
    }

    static func palette(seed: Int) -> [Color] {
        palettes[abs(seed) % palettes.count]
    }

    /// The one colour that stands for a field, so chrome can be tinted to match
    /// a blank tab the same way it is tinted from a real page. The first accent
    /// rather than the deep base — the base is nearly black and would read as no
    /// tint at all.
    static func signature(seed: Int) -> Color {
        let colors = palette(seed: seed)
        return colors.count > 1 ? colors[1] : (colors.first ?? .clear)
    }

    private var blobs: [Blob] {
        var rand = Rand(seed)
        let colors = palette.dropFirst()
        return colors.enumerated().map { index, color in
            Blob(id: index,
                 color: color,
                 unitX: rand.inRange(0.05, 0.95),
                 unitY: rand.inRange(0.05, 0.95),
                 scale: rand.inRange(0.55, 1.15))
        }
    }

    /// Drives the ambient drift. Flipped once on appear; the animation repeats.
    @State private var drifting = false
    /// Entrance: the field settles in from very slightly overscaled.
    @State private var settled = false

    var body: some View {
        field
            // Overscaled so the rotation can't expose a corner. At ±4° on a
            // wide rect, 1.14 is the floor; 1.18 leaves room for the breathe.
            .scaleEffect(drifting ? 1.26 : 1.18)
            .rotationEffect(.degrees(drifting ? 4 : -4))
            .offset(x: drifting ? 18 : -18, y: drifting ? -12 : 12)
            .animation(Motion.reduced
                       ? nil
                       : .easeInOut(duration: 26).repeatForever(autoreverses: true),
                       value: drifting)
            // Jelly entrance: squash wide and short, then rebound. Anisotropic
            // and under-damped, which is what separates jelly from a zoom.
            .scaleEffect(x: settled ? 1 : 1.06, y: settled ? 1 : 0.94)
            .opacity(settled ? 1 : 0)
            .animation(Motion.jelly, value: settled)
            // Clipped, not hit-test-disabled: the caller layers a
            // click-outside-to-dismiss tap on this, and a non-hittable child
            // would leave that gesture with nothing to hit.
            .clipped()
            .onAppear {
                settled = true
                drifting = true
            }
    }

    private var field: some View {
        GeometryReader { geo in
            let span = max(geo.size.width, geo.size.height)
            ZStack {
                palette.first ?? Color.black

                ForEach(blobs) { blob in
                    Circle()
                        .fill(blob.color)
                        .frame(width: span * blob.scale, height: span * blob.scale)
                        .position(x: geo.size.width * blob.unitX,
                                  y: geo.size.height * blob.unitY)
                        .blur(radius: span * 0.18)
                }

                // A faint sheen so it reads as glass rather than a poster.
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                Color.black.opacity(dimming)
            }
            .drawingGroup()   // flatten to one layer; the blur is paid once
        }
        .ignoresSafeArea()
    }
}

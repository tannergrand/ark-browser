import SwiftUI

/// A rounded rectangle whose top and bottom edges ripple, with the ripple
/// travelling sideways — the command bar behaving like a body of jelly a
/// keystroke just dropped into.
///
/// This has to be a `Shape` rather than a transform. A `scaleEffect` or
/// `geometryEffect` is affine: it can squash the whole bar, but it cannot bend
/// one part of an edge while leaving the rest alone, so it can't make a wave that
/// *travels*. A Shape can, because the path is rebuilt each frame.
///
/// The text field is untouched on purpose. It's a hosted `NSView`, so distorting
/// it would mean distorting a live text cursor and glyphs mid-edit — which reads
/// as broken, not soft. The edges ripple, the text stays legible.
///
/// Cost: a path rebuild plus a glass re-clip per frame, but only while a wave is
/// alive (~0.5s after the last keystroke). Idle, it is a plain rounded rect.
struct JellyWave: Shape, Animatable {
    /// Advances by 1 per keystroke; the crest travels one full width each time.
    var phase: Double
    /// 0…1. Scales the ripple; decays to nothing between keystrokes.
    var amplitude: Double
    var cornerRadius: CGFloat = 14

    /// How far an edge can bow, at full amplitude.
    private let peak: CGFloat = 3.2
    /// Roughly two crests across the bar. More reads as corrugation.
    private let waves: Double = 2.0

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, amplitude) }
        set { phase = newValue.first; amplitude = newValue.second }
    }

    /// Vertical displacement at a given horizontal position, tapered to zero at
    /// both ends so the corners stay put — a wave that moved the corners would
    /// look like the whole bar was sliding.
    func displacement(at x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, amplitude > 0.001 else { return 0 }
        let t = Double(x / width)
        let taper = sin(t * .pi)                       // 0 at edges, 1 mid-span
        let wave = sin(t * .pi * 2 * waves - phase * .pi * 2)
        return peak * CGFloat(amplitude * taper * taper * wave)
    }

    func path(in rect: CGRect) -> Path {
        guard amplitude > 0.001 else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        }
        var path = Path()
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let steps = 28
        let usable = rect.width - radius * 2

        // Top edge, left to right.
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let x = rect.minX + radius + usable * progress
            path.addLine(to: CGPoint(x: x, y: rect.minY + displacement(at: x - rect.minX,
                                                                      width: rect.width)))
        }
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                    radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                    radius: radius, startAngle: .degrees(0), endAngle: .degrees(90),
                    clockwise: false)

        // Bottom edge, right to left. Same wave, opposite sign, so the bar
        // thickens and thins rather than shifting bodily up and down.
        for step in 1...steps {
            let progress = 1 - CGFloat(step) / CGFloat(steps)
            let x = rect.minX + radius + usable * progress
            path.addLine(to: CGPoint(x: x, y: rect.maxY - displacement(at: x - rect.minX,
                                                                      width: rect.width)))
        }
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                    radius: radius, startAngle: .degrees(90), endAngle: .degrees(180),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                    radius: radius, startAngle: .degrees(180), endAngle: .degrees(270),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Drives a `JellyWave`: each keystroke sends one crest across, and the ripple
/// dies down if you stop typing.
@Observable
final class JellyWaveDriver {
    var phase: Double = 0
    var amplitude: Double = 0

    @ObservationIgnored private var decayTask: Task<Void, Never>?

    /// Called per keystroke. Typing fast keeps the water moving; the amplitude
    /// tops up rather than restarting, so a burst builds instead of stuttering.
    @MainActor
    func strike(reduced: Bool) {
        guard !reduced else { return }
        withAnimation(.linear(duration: 0.62)) { phase += 1 }
        withAnimation(.easeOut(duration: 0.09)) { amplitude = min(1, amplitude + 0.7) }

        decayTask?.cancel()
        decayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.55)) { self?.amplitude = 0 }
        }
    }
}

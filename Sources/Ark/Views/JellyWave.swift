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
    /// 0…1. How far the crest has travelled from where it started.
    var travel: Double
    /// 0…1. Where along the bar the ripple was born — the caret, roughly.
    var origin: Double
    /// 0…1. Scales the whole thing; decays to nothing between keystrokes.
    var amplitude: Double
    var cornerRadius: CGFloat = 14

    /// How far an edge can bow, at full amplitude.
    private let peak: CGFloat = 3.6
    /// Width of the crest as a fraction of the bar. Narrow enough to read as a
    /// single wave passing through rather than the whole bar flexing.
    private let width: Double = 0.26

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(travel, AnimatablePair(origin, amplitude)) }
        set {
            travel = newValue.first
            origin = newValue.second.first
            amplitude = newValue.second.second
        }
    }

    /// Vertical displacement at a horizontal position.
    ///
    /// A packet, not a standing wave: it starts at `origin` and moves right, so
    /// typing pushes a ripple ahead of the caret. The crest fades as it goes and
    /// the ends are pinned, so the corners never move — a wave that shifted the
    /// corners would look like the bar sliding rather than rippling.
    func displacement(at x: CGFloat, width barWidth: CGFloat) -> CGFloat {
        guard barWidth > 0, amplitude > 0.001 else { return 0 }
        let t = Double(x / barWidth)
        let crest = origin + travel * (1.15 - origin)
        let distance = (t - crest) / self.width
        guard abs(distance) < 3 else { return 0 }

        let envelope = exp(-distance * distance)         // the packet
        let ripple = cos(distance * .pi)                 // one crest, two troughs
        let ends = sin(min(max(t, 0), 1) * .pi)          // pinned at both ends
        let fade = 1 - travel * 0.45                     // loses energy as it runs
        return peak * CGFloat(amplitude * envelope * ripple * ends * fade)
    }

    func path(in rect: CGRect) -> Path {
        guard amplitude > 0.001 else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        }
        var path = Path()
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        // Denser sampling than the old standing wave needed: a narrow packet
        // sampled coarsely turns into a visible kink.
        let steps = 44
        let usable = rect.width - radius * 2

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

        // Bottom edge mirrors the top, so the bar thickens and thins rather than
        // shifting bodily up and down.
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

/// Drives a `JellyWave`: each keystroke drops a ripple at the caret and sends it
/// rightward.
@Observable
final class JellyWaveDriver {
    var travel: Double = 0
    var origin: Double = 0
    var amplitude: Double = 0

    @ObservationIgnored private var decayTask: Task<Void, Never>?

    /// `caret` is 0…1 across the field, so the wave starts where you're typing
    /// and runs ahead of it — which is what makes it read as left-to-right rather
    /// than the whole bar wobbling in place.
    @MainActor
    func strike(caret: Double, reduced: Bool) {
        guard !reduced else { return }

        // Restart the packet at the caret with no animation, then animate the
        // run. Animating the origin as well would drag the previous crest across
        // the bar instead of dropping a new one.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            travel = 0
            origin = min(max(caret, 0), 1)
        }
        withAnimation(.easeOut(duration: 0.75)) { travel = 1 }
        withAnimation(.easeOut(duration: 0.08)) { amplitude = 1 }

        decayTask?.cancel()
        decayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { self?.amplitude = 0 }
        }
    }
}

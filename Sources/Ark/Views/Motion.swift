import AppKit
import SwiftUI

/// Jelly-flavoured motion, translated for a native app.
///
/// The Jelly UI library gets its squish by simulating soft-body physics on a
/// `<canvas>`. Reproducing that here would mean per-frame CPU work inside a
/// browser — the expensive way to buy a feel. A spring with low damping
/// produces the same overshoot-and-settle read, and SwiftUI animates transform
/// and opacity on the GPU, so the cost is effectively zero.
///
/// Rules that keep this frugal, and worth preserving:
///   • Only `scaleEffect` and `opacity` are animated. Never shadow, blur, or
///     colour — those force off-screen passes on every frame.
///   • Nothing repeats. Every animation is driven by a discrete state change,
///     so idle chrome costs nothing at all.
///   • Reduce Motion collapses springs to short fades rather than disabling
///     feedback outright.
enum Motion {
    /// Read once per launch; the system posts a notification on change, but the
    /// window is rebuilt on relaunch and this keeps it off the hot path.
    static let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Press feedback — quick, with a little overshoot on release.
    static var squish: Animation {
        reduced ? .easeOut(duration: 0.10)
                : .spring(response: 0.26, dampingFraction: 0.58)
    }

    /// Panels and overlays arriving. A touch more damping so it doesn't wobble.
    static var pop: Animation {
        reduced ? .easeOut(duration: 0.12)
                : .spring(response: 0.30, dampingFraction: 0.70)
    }

    /// Layout settling — sidebar reveal, split resize, disclosure.
    static var settle: Animation {
        reduced ? .easeOut(duration: 0.12)
                : .spring(response: 0.34, dampingFraction: 0.82)
    }

    /// Leaving. Deliberately faster than arriving; slow exits feel sluggish.
    static var exit: Animation { .easeOut(duration: reduced ? 0.08 : 0.16) }

    static let pressScale: CGFloat = 0.965

    /// Sidebar rows. Springier than `squish` — a tab list is the thing you touch
    /// most, so it's where the softness is worth spending frames on.
    static var rowSquish: Animation {
        reduced ? .easeOut(duration: 0.10)
                : .spring(response: 0.30, dampingFraction: 0.48)
    }

    /// Selection settling into place.
    static var select: Animation {
        reduced ? .easeOut(duration: 0.10)
                : .spring(response: 0.34, dampingFraction: 0.52)
    }

    /// A row lifting under the pointer while dragging.
    static var lift: Animation {
        reduced ? .easeOut(duration: 0.10)
                : .spring(response: 0.26, dampingFraction: 0.5)
    }

    /// The jelly spring: deliberately under-damped so it overshoots and settles
    /// back. Damping much below 0.5 starts to read as broken rather than soft.
    static var jelly: Animation {
        reduced ? .easeOut(duration: 0.12)
                : .spring(response: 0.40, dampingFraction: 0.55)
    }

    /// Squash-and-stretch entrance. Under Reduce Motion it becomes a plain fade.
    ///
    /// The jelly read comes from the scale being *anisotropic* — wider than it
    /// is tall on the way in, so it visibly squashes and rebounds. A uniform
    /// scale, which is what this used to do, just looks like a zoom.
    static var appear: AnyTransition {
        reduced
            ? .opacity
            : .asymmetric(
                insertion: .modifier(active: JellyStretch(amount: 1),
                                     identity: JellyStretch(amount: 0)),
                removal: .opacity)
    }
}

/// Anisotropic scale plus fade, driven by a single 0…1 amount so it can be used
/// as a transition modifier. Both are GPU-side, so the cost is a transform.
struct JellyStretch: ViewModifier, Animatable {
    var amount: Double

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1 + amount * 0.075, y: 1 - amount * 0.11, anchor: .top)
            .opacity(1 - amount)
    }
}

/// Squash-and-stretch on press, for buttons that should feel soft rather than
/// merely dented — the New Tab row, most of all.
struct JellySquashButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(x: configuration.isPressed ? 1.03 : 1,
                         y: configuration.isPressed ? 0.88 : 1)
            .animation(Motion.rowSquish, value: configuration.isPressed)
    }
}

/// Squish-on-press for any button. The dent is a scale, so it costs one
/// GPU transform and no layout pass.
struct JellyPress: ButtonStyle {
    var scale: CGFloat = Motion.pressScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.squish, value: configuration.isPressed)
    }
}

/// Hover/press squish for rows that aren't Buttons (sidebar tabs, groups).
struct JellySquish: ViewModifier {
    let pressed: Bool
    var scale: CGFloat = Motion.pressScale

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1)
            .animation(Motion.squish, value: pressed)
    }
}

/// The sidebar-row treatment: squash on press, a nudge on hover, a lift while
/// being dragged. Anisotropic again — a row squashing wider than it is tall is
/// the difference between jelly and a zoom.
struct JellyRow: ViewModifier {
    var pressed: Bool = false
    var hovering: Bool = false
    var dragging: Bool = false
    var selected: Bool = false
    /// Where the press landed. The squash pivots here, so a click on the left of
    /// a row compresses toward the left — the row gives way under your finger
    /// rather than shrinking uniformly toward its middle.
    var anchor: UnitPoint = .center

    private var scaleX: CGFloat {
        if dragging { return 1.03 }
        if pressed { return 1.035 }
        if hovering { return 1.012 }
        return 1
    }

    private var scaleY: CGFloat {
        if dragging { return 1.04 }
        if pressed { return 0.90 }
        if hovering { return 1.02 }
        return 1
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: anchor)
            .shadow(color: .black.opacity(dragging ? 0.28 : 0),
                    radius: dragging ? 8 : 0, y: dragging ? 3 : 0)
            .animation(Motion.rowSquish, value: pressed)
            .animation(Motion.lift, value: dragging)
            .animation(Motion.squish, value: hovering)
            .animation(Motion.select, value: selected)
    }
}

extension View {
    /// Button style with the jelly dent.
    func jellyPress(scale: CGFloat = Motion.pressScale) -> some View {
        buttonStyle(JellyPress(scale: scale))
    }

    /// Manual squish for non-button rows.
    func jellySquish(pressed: Bool, scale: CGFloat = Motion.pressScale) -> some View {
        modifier(JellySquish(pressed: pressed, scale: scale))
    }

    /// Sidebar rows: press, hover, drag, and selection in one modifier.
    func jellyRow(pressed: Bool = false, hovering: Bool = false,
                  dragging: Bool = false, selected: Bool = false,
                  anchor: UnitPoint = .center) -> some View {
        modifier(JellyRow(pressed: pressed, hovering: hovering,
                          dragging: dragging, selected: selected, anchor: anchor))
    }

    /// Entrance for overlays and panels.
    func jellyAppear() -> some View {
        transition(Motion.appear).animation(Motion.jelly, value: true)
    }
}

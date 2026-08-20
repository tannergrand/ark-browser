import SwiftUI

/// Liquid Glass chrome, gated on availability and on a user setting.
///
/// Verified present in this SDK: `glassEffect(_:in:)`, `GlassEffectContainer`,
/// `.buttonStyle(.glass)`, and `Glass.regular.interactive().tint(_:)`. The app's
/// deployment floor stays at macOS 14, so every call site is behind
/// `#available` and falls back to a material.
///
/// Cost note, since frugality is the constraint: glass is a real-time
/// refraction pass, so it is priced per *area*. Ark applies it to chrome —
/// edges, rims, and small floating panels — and never behind live web content,
/// which is the large-area case that would actually cost battery. `interactive`
/// adds pointer tracking, so it is reserved for small controls.
enum GlassStyle {
    case chrome      // sidebar, panels — plain regular glass
    case floating    // command bar, popovers — regular glass, slightly tinted
    case control     // small buttons — interactive
}

/// How the 0…1 intensity slider maps onto the actual effect.
///
/// `glassEffect` has no intensity parameter, so intensity is expressed through
/// the things that *are* continuous: tint strength, rim highlight, and whether
/// small controls get the pointer-tracking `interactive` variant. Below
/// `offThreshold` glass is skipped entirely rather than rendered invisibly —
/// paying for a refraction pass nobody can see is the wasteful case.
enum GlassRamp {
    static let offThreshold = 0.04

    static func tintOpacity(_ intensity: Double) -> Double {
        0.015 + 0.10 * intensity
    }

    static func rimHighlight(_ intensity: Double) -> Double {
        0.05 + 0.26 * intensity
    }

    /// Pointer tracking costs a little, so only earn it at higher settings.
    static func interactive(_ intensity: Double) -> Bool {
        intensity >= 0.55
    }

    static func active(_ enabled: Bool, _ intensity: Double) -> Bool {
        enabled && intensity > offThreshold
    }
}

extension View {
    /// Glass surface in the given shape, with a material fallback.
    @ViewBuilder
    func glassSurface<S: Shape>(_ style: GlassStyle = .chrome,
                                in shape: S,
                                enabled: Bool = true,
                                intensity: Double = 0.6) -> some View {
        if GlassRamp.active(enabled, intensity), #available(macOS 26.0, *) {
            switch style {
            case .chrome:
                self.glassEffect(.regular, in: shape)
            case .floating:
                self.glassEffect(
                    .regular.tint(.accentColor.opacity(GlassRamp.tintOpacity(intensity))),
                    in: shape)
            case .control:
                if GlassRamp.interactive(intensity) {
                    self.glassEffect(.regular.interactive(), in: shape)
                } else {
                    self.glassEffect(.regular, in: shape)
                }
            }
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// A thin glass rim. This is the "border" treatment — cheap, because the
    /// glass only covers the stroke, not the whole surface.
    /// `tint` blends the chrome colour into the rim, so the outline around the
    /// page belongs to the same surface as the sidebar instead of reading as a
    /// grey border between two tinted things.
    @ViewBuilder
    func glassRim(cornerRadius: CGFloat,
                  lineWidth: CGFloat = 1,
                  enabled: Bool = true,
                  intensity: Double = 0.6,
                  tint: Color? = nil) -> some View {
        if GlassRamp.active(enabled, intensity) {
            let highlight = GlassRamp.rimHighlight(intensity)
            self.overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [(tint ?? .white).opacity(highlight * 1.6),
                                     (tint ?? .white).opacity(highlight * 0.45),
                                     .black.opacity(highlight * 0.30)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: lineWidth)
            }
        } else {
            self.overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: lineWidth)
            }
        }
    }

    /// Groups nearby glass elements so they blend instead of stacking passes —
    /// this is the frugal way to have several glass panels on screen at once.
    @ViewBuilder
    func glassGroup(enabled: Bool = true) -> some View {
        if enabled, #available(macOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }
}

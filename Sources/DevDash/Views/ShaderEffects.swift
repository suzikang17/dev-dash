import SwiftUI

// MARK: - Animated GPU gradient text

extension View {
    /// Fills the view's opaque pixels (e.g. the glyphs of a `Text`) with an
    /// animated "aurora" gradient computed on the GPU.
    ///
    /// Backed by `Aurora.metal` → `aurora()`, compiled to `default.metallib`
    /// and shipped in the app bundle. See `run.sh` for the compile/copy step.
    func auroraText() -> some View {
        modifier(AuroraTextModifier())
    }
}

private struct AuroraTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        // TimelineView(.animation) re-evaluates every frame, handing us a fresh
        // `date`. We turn that into a small, ever-changing `time` value and pass
        // it to the shader — that's what makes the gradient flow.
        TimelineView(.animation) { context in
            content.colorEffect(
                ShaderLibrary.default.aurora(.float(shaderTime(context.date)))
            )
        }
    }
}

/// Keep the magnitude small: a 32-bit float only holds ~7 digits, so feeding it
/// raw epoch seconds (~1.8e9) would lose sub-second precision and any shader
/// animation would visibly stutter. Wrapping to a 0–1000 window keeps it smooth.
private func shaderTime(_ date: Date) -> Double {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
}

// MARK: - AI-working shimmer

extension View {
    /// Sweeps a translucent light streak across the view while `active` is true
    /// (e.g. a task whose agent is currently running). Costs nothing when
    /// inactive — the animated branch isn't even built.
    @ViewBuilder
    func workingShimmer(active: Bool, cornerRadius: CGFloat = DSRadius.small) -> some View {
        if active {
            overlay(
                TimelineView(.animation) { context in
                    Rectangle()
                        .colorEffect(ShaderLibrary.default.aiShimmer(.float(shaderTime(context.date))))
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}

// MARK: - Health aura

extension View {
    /// Draws a soft, breathing radial glow behind the view in `tint` while
    /// `active` (e.g. a project that needs attention). Sized a bit larger than
    /// the content so the halo extends past a small status dot.
    @ViewBuilder
    func healthAura(_ tint: Color, active: Bool, diameter: CGFloat = 22) -> some View {
        if active {
            background(
                TimelineView(.animation) { context in
                    Circle()
                        .colorEffect(ShaderLibrary.default.healthAura(
                            .boundingRect, .float(shaderTime(context.date)), .color(tint)))
                }
                .frame(width: diameter, height: diameter)
                .blur(radius: 1.5)
                .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}

// MARK: - Diff gutter glow

/// A static gutter-anchored gradient in `tint`, used as a diff row-cell
/// background. No animation, so it adds no per-frame cost.
struct DiffGlowBackground: View {
    let tint: Color
    var body: some View {
        Rectangle()
            .colorEffect(ShaderLibrary.default.diffGlow(.boundingRect, .color(tint)))
    }
}

// MARK: - Nebula empty-state background

/// A subtle, slowly drifting dark field for empty states. Held at low opacity
/// so placeholder text stays legible. Only renders while its empty state is on
/// screen, so it stops animating the moment content appears.
struct NebulaBackground: View {
    var opacity: Double = 0.22
    var body: some View {
        TimelineView(.animation) { context in
            Rectangle()
                .colorEffect(ShaderLibrary.default.nebula(.float(shaderTime(context.date))))
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

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
            // Keep the magnitude small: a 32-bit float only holds ~7 digits, so
            // feeding it raw epoch seconds (~1.8e9) would lose sub-second
            // precision and the animation would visibly stutter. Wrapping to a
            // 0–1000 window keeps it smooth.
            let time = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1000)
            content.colorEffect(
                ShaderLibrary.default.aurora(.float(time))
            )
        }
    }
}

import SwiftUI

// MARK: - SimulatorView

/// Top-level view for the global Simulator destination. The actual simulator
/// surface (baguette server, live embed, Build & Run pipeline) lives in the
/// reusable `SimulatorEmbedView`; here it runs unscoped (`fixedProject == nil`),
/// so the Build & Run panel lets the user pick any dashboard project with an
/// Xcode workspace/project. The same view is hosted, project-scoped, in the
/// Preview tab's iOS mode.
struct SimulatorView: View {
    var body: some View {
        SimulatorEmbedView(fixedProject: nil)
    }
}

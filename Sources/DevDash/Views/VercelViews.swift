import SwiftUI

/// Color for a Vercel deployment state, matching the app's status palette.
func vercelStateColor(_ state: String) -> Color {
    switch state.uppercased() {
    case "READY": return DSColor.success
    case "BUILDING", "QUEUED", "INITIALIZING": return DSColor.warning
    case "ERROR", "CANCELED", "BLOCKED", "DELETED": return DSColor.danger
    default: return .secondary
    }
}

/// Colored dot + lowercased state label (e.g. ● ready).
struct VercelStateBadge: View {
    let state: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(vercelStateColor(state)).frame(width: 6, height: 6)
            Text(state.lowercased())
                .font(DSFont.micro)
                .foregroundColor(vercelStateColor(state))
        }
    }
}

/// "production" / "preview" pill.
struct VercelTargetTag: View {
    let isProduction: Bool
    var body: some View {
        Text(isProduction ? "prod" : "preview")
            .font(DSFont.micro)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background((isProduction ? DSColor.success : Color.secondary).opacity(0.14))
            .foregroundColor(isProduction ? DSColor.success : .secondary)
            .clipShape(Capsule())
    }
}

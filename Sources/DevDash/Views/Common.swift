import SwiftUI

struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.6))
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.6 : 1)
                .opacity(pulse ? 0 : 0.7)
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        }
        .onAppear { pulse = true }
    }
}

func timeAgo(_ date: Date?) -> String {
    guard let date = date else { return "—" }
    let secs = Int(Date().timeIntervalSince(date))
    if secs < 60 { return "just now" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    if secs < 86400 { return "\(secs / 3600)h ago" }
    let days = secs / 86400
    if days < 30 { return "\(days)d ago" }
    return "\(days / 30)mo ago"
}

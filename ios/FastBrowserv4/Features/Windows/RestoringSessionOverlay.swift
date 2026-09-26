import SwiftUI

/// Shown over a grid cell that is holding its page load until the cloned
/// session lands in its store. A slow cyan sweep over a dimmed tile — quiet
/// enough to read as "waiting", not as an error or a blocking spinner.
struct RestoringSessionOverlay: View {
    var compact: Bool = false
    @State private var sweep: CGFloat = -1

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, Cockpit.live.opacity(0.28), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.6)
                .offset(x: sweep * geo.size.width)
                .blur(radius: 8)
            }
            .allowsHitTesting(false)

            VStack(spacing: compact ? 3 : 6) {
                Image(systemName: "person.2.badge.key.fill")
                    .font(compact ? .system(size: 13, weight: .bold) : .title3.weight(.bold))
                    .foregroundStyle(Cockpit.live)
                Text("Restoring session")
                    .font(compact
                          ? .system(size: 8, weight: .heavy, design: .rounded)
                          : .system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(compact ? 8 : 14)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                sweep = 1.2
            }
        }
        .transition(.opacity)
        .accessibilityLabel("Restoring session")
    }
}

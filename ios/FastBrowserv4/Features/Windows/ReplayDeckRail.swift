import SwiftUI

/// Right-edge Replay deck: one numbered circle per frozen Joe Fortune /
/// Ignition login, in run order (circle 1 = first success of the batch).
/// Tapping a circle paints that still-signed-in session across the full
/// screen; long-press offers to forget it.
struct ReplayDeckRail: View {
    let viewModel: BrowserViewModel

    private var sessions: [ParkedSession] {
        viewModel.replayDeck
    }

    var body: some View {
        VStack(spacing: 8) {
            closeButton

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        circle(for: session, number: index + 1)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 8)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background {
            Rectangle().fill(.clear).glassEffect()
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.replaySelectedID)
        .accessibilityLabel("Session deck, \(sessions.count) saved logins")
    }

    private var closeButton: some View {
        Button {
            viewModel.exitReplayMode()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close deck")
    }

    private func circle(for session: ParkedSession, number: Int) -> some View {
        let isSelected = session.id == viewModel.replaySelectedID
        let tint = session.replaySite?.tint ?? .gray

        return Button {
            viewModel.selectReplaySession(session)
        } label: {
            Text("\(number)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.gradient))
                .overlay {
                    Circle()
                        .stroke(
                            Color.white.opacity(isSelected ? 0.95 : 0.18),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .shadow(color: tint.opacity(isSelected ? 0.9 : 0.25), radius: isSelected ? 9 : 3)
                .scaleEffect(isSelected ? 1.14 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isSelected)
        .contextMenu {
            Section("\(session.username) · \(session.replaySite?.label ?? session.domain)") {
                Button("Forget session", systemImage: "trash", role: .destructive) {
                    viewModel.forgetReplaySession(session)
                }
            }
        }
        .accessibilityLabel(
            "Session \(number), \(session.replaySite?.label ?? session.domain), \(session.username)"
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private extension ReplaySite {
    /// Green = Joe Fortune, red = Ignition.
    var tint: Color {
        switch self {
        case .joeFortune: return Color(red: 0.16, green: 0.78, blue: 0.44)
        case .ignition: return Color(red: 0.93, green: 0.24, blue: 0.29)
        }
    }
}

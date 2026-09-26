import SwiftUI

/// Which edge a piece of chrome tucks away towards.
enum HideEdge {
    case top
    case bottom

    /// Sign of a drag that hides the content.
    var hideDirection: CGFloat { self == .top ? -1 : 1 }

    var transitionEdge: Edge { self == .top ? .top : .bottom }

    /// Glyph on the restore tab — points back the way the chrome went.
    var restoreIcon: String { self == .top ? "chevron.down" : "chevron.up" }
}

/// How the restore affordance looks once the content is hidden.
enum HideRestoreStyle: Equatable {
    /// A bare grabber bar. For chrome that is obviously missing when gone,
    /// like the address bar.
    case grabber
    /// A labelled pill. For chrome you might not realise you hid, like a
    /// run queue that is still doing work out of sight.
    case labelled(String)
    /// A small circular chevron. For chrome floating over live content.
    case chevron
}

/// One swipe-to-hide behaviour for every piece of chrome in the app.
///
/// There used to be five separate implementations of this — the address bar,
/// the second address bar, the bottom toolbar, the run queue pills and the
/// Follow the Leader strip — each with its own threshold, its own spring and
/// its own idea of what the restore tab looked like. They had drifted: one
/// hid after 20 points of drag, another after 60, and only two of them
/// refused to hide while the keyboard was up.
///
/// - Parameters:
///   - isVisible: hidden state, owned by the caller so it can be reset.
///   - edge: which way the content tucks away.
///   - restore: what the user taps to bring it back.
///   - isLocked: blocks hiding entirely — used while a text field is being
///     edited, so an accidental drag can't dismiss the field being typed in.
struct SwipeToHide<Content: View>: View {
    @Binding var isVisible: Bool
    var edge: HideEdge = .bottom
    var restore: HideRestoreStyle = .chevron
    var accessibilityLabel: String
    var isLocked: Bool = false
    @ViewBuilder var content: () -> Content

    /// Past this much drag in the hiding direction, let go and it stays hidden.
    private let threshold: CGFloat = 28

    @State private var drag: CGFloat = 0

    var body: some View {
        if isVisible {
            content()
                .offset(y: drag)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard !isLocked else { return }
                            // Only travel in the hiding direction, so the
                            // chrome never peels away from its own edge.
                            let raw = value.translation.height
                            drag = edge == .bottom ? max(0, raw) : min(0, raw)
                        }
                        .onEnded { value in
                            guard !isLocked else { return }
                            let travelled = value.translation.height * edge.hideDirection
                            if travelled > threshold {
                                withAnimation(Cockpit.Motion.panel) {
                                    isVisible = false
                                    drag = 0
                                }
                            } else {
                                withAnimation(Cockpit.Motion.panel) { drag = 0 }
                            }
                        }
                )
                .transition(.move(edge: edge.transitionEdge).combined(with: .opacity))
        } else {
            restoreControl
                .transition(.opacity)
        }
    }

    private var restoreControl: some View {
        Button {
            withAnimation(Cockpit.Motion.panel) {
                isVisible = true
                drag = 0
            }
        } label: {
            restoreLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var restoreLabel: some View {
        switch restore {
        case .grabber:
            Capsule()
                .fill(Cockpit.hairlineStrong)
                .frame(width: 36, height: 5)
                .padding(.vertical, Cockpit.Space.tight)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        case .labelled(let text):
            HStack(spacing: Cockpit.Space.hair + 2) {
                Image(systemName: edge.restoreIcon)
                    .font(.caption2.bold())
                Text(text)
                    .font(.cockpitChip)
            }
            .foregroundStyle(Cockpit.live)
            .padding(.horizontal, Cockpit.Space.snug)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(Cockpit.live).interactive(), in: .capsule)
        case .chevron:
            Image(systemName: edge.restoreIcon)
                .font(.caption2.bold())
                .foregroundStyle(Cockpit.textPrimary)
                .padding(Cockpit.Space.tight)
                .glassEffect(in: .circle)
        }
    }
}

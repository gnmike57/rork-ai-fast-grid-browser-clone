import SwiftUI

/// The two things you do *right now*, floating over the page: start a run,
/// and fill cards.
///
/// These used to sit in a row of eight controls with Burn — a destructive,
/// session-throwing-away action — wedged between them. Pulling them out into
/// their own dock means the two buttons pressed constantly are large, close
/// to the thumb, and nowhere near anything that destroys work.
struct ActionDock<CardMenu: View>: View {
    let isRunning: Bool
    let runProgress: CGFloat
    let cardCount: Int
    let isAutoFillArmed: Bool
    /// Bumped by the owner on every card press, so the button reacts instantly
    /// rather than waiting for the injected fill to report back.
    let cardPressPulse: Int

    let onRun: () -> Void
    let onFillCards: () -> Void
    @ViewBuilder let cardMenu: () -> CardMenu

    @State private var isCardPressed: Bool = false

    var body: some View {
        HStack(spacing: Cockpit.Space.snug) {
            cardButton
            runButton
        }
        .padding(.horizontal, Cockpit.Space.snug)
        .padding(.vertical, Cockpit.Space.tight)
        .cockpitFloating(radius: Cockpit.Radius.dock)
    }

    // MARK: - Run

    private var runButton: some View {
        Button(action: onRun) {
            ZStack {
                Circle()
                    .fill(.linearGradient(
                        colors: [Cockpit.live, Cockpit.live.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 46, height: 46)
                    .shadow(color: Cockpit.live.opacity(isRunning ? 0.65 : 0.25), radius: 12)
                    .scaleEffect(isRunning ? 1.05 : 1)
                    .animation(
                        isRunning
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: isRunning
                    )

                if isRunning {
                    Circle()
                        .trim(from: 0, to: runProgress)
                        .stroke(
                            Cockpit.onAccent.opacity(0.9),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 42, height: 42)
                        .animation(.easeInOut(duration: 0.25), value: runProgress)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Cockpit.onAccent)
                        .frame(width: 11, height: 11)
                } else {
                    Text("RCR")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(Cockpit.onAccent)
                        .kerning(0.5)
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRunning ? "Stop the run" : "Start a run")
    }

    // MARK: - Cards

    private var cardButton: some View {
        Menu {
            cardMenu()
        } label: {
            cardLabel
        } primaryAction: {
            onFillCards()
        }
        .accessibilityLabel(
            cardCount == 0
                ? "Add a card"
                : "Fill cards in every window. \(cardCount) card\(cardCount == 1 ? "" : "s") saved\(isAutoFillArmed ? ", auto-fill armed" : "")"
        )
        .onChange(of: cardPressPulse) { _, _ in
            isCardPressed = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                isCardPressed = false
            }
        }
    }

    private var cardLabel: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(.linearGradient(
                        colors: [Cockpit.card, Cockpit.card.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 42, height: 42)
                    .shadow(color: Cockpit.card.opacity(isAutoFillArmed ? 0.6 : 0.2), radius: 10)

                Image(systemName: "creditcard.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Cockpit.onAccent)
            }
            .scaleEffect(isCardPressed ? 1.16 : 1)

            if cardCount > 0 {
                Text("\(cardCount)")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Cockpit.onAccent)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Cockpit.textPrimary))
                    .overlay(Circle().strokeBorder(Cockpit.card, lineWidth: 1))
                    .offset(x: 3, y: -2)
            }

            if isAutoFillArmed {
                // Armed auto-fill is the one card setting that changes what
                // happens without you pressing anything, so it gets a
                // permanent tell rather than living only in the menu.
                Circle()
                    .fill(Cockpit.success)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Cockpit.canvas, lineWidth: 1.5))
                    .offset(x: 0, y: 38)
            }
        }
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .animation(.spring(response: 0.26, dampingFraction: 0.5), value: isCardPressed)
    }
}

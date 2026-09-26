import SwiftUI

/// Translucent pill that shows the current RCR target plus the next 8
/// credentials in the queue, with a collapsible completed list underneath.
/// Also hosts the run cockpit: live speed dial, pause/resume, skip, retry,
/// and (in grid mode) a per-window freeze control.
struct QueuePillView: View {
    let title: String
    let titleColor: Color
    let statusDotColor: Color
    let statusLabel: String
    let isWaitingPulse: Bool
    let total: Int
    let completedCount: Int
    let upcoming: [RCRQueueItem]   // includes current as the first item
    let completed: [RCRQueueItem]
    let pulseTrigger: Int          // anything that changes when state advances
    /// Optional "View Results" action shown when the run is finished.
    let onViewResults: (() -> Void)?

    // MARK: - Run cockpit (all optional with sensible defaults)

    var speedProfile: SpeedProfile = .normal
    var onSpeedChange: (SpeedProfile) -> Void = { _ in }
    var isPaused: Bool = false
    var onTogglePause: () -> Void = {}
    var onSkip: () -> Void = {}
    var onRetry: () -> Void = {}
    /// Non-nil in grid mode — shows the per-window freeze control.
    var isFrozen: Bool = false
    var onToggleFreeze: (() -> Void)? = nil

    @State private var showAll: Bool = false
    @State private var showCompleted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            cockpitRow
            if let current = upcoming.first {
                currentRow(current)
            }

            if upcoming.count > 1 {
                Divider().opacity(0.25)
                Text("NEXT \(min(upcoming.count - 1, 8))")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)

                VStack(spacing: 4) {
                    ForEach(Array(upcoming.dropFirst().prefix(8))) { item in
                        upcomingRow(item)
                    }
                }
            }

            if !completed.isEmpty {
                Divider().opacity(0.25)
                Button {
                    withAnimation(.snappy) { showCompleted.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("DONE \(completed.count) / \(total)")
                            .font(.system(size: 9, weight: .heavy))
                            .kerning(0.6)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showCompleted ? "Hide completed" : "Show completed")

                if showCompleted {
                    // Lazy + height-capped: a finished run's completed list
                    // can be the whole vault, and the pill must not have to
                    // render (or grow to fit) hundreds of rows at once.
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(completed) { item in
                                completedRow(item)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if let onViewResults, total > 0 && completedCount >= total {
                Button(action: onViewResults) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("View Results")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Cockpit.live)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Cockpit.live.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Circle()
                    .stroke(statusDotColor.opacity(0.4), lineWidth: 4)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isWaitingPulse ? 1.8 : 1)
                    .opacity(isWaitingPulse ? 0 : 1)
                    .animation(
                        isWaitingPulse
                            ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                            : .default,
                        value: isWaitingPulse
                    )
            }
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(titleColor)
                .kerning(0.5)
            Text("\(min(completedCount, total)) / \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    // MARK: - Cockpit

    /// Live speed dial + pause/skip/retry/freeze controls, all in the same
    /// glass/cyan/monospaced visual family as the rest of the pill.
    private var cockpitRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(SpeedProfile.allCases) { profile in
                    Button {
                        onSpeedChange(profile)
                    } label: {
                        Image(systemName: profile.systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(speedProfile == profile ? AnyShapeStyle(Cockpit.live) : AnyShapeStyle(.secondary))
                            .frame(width: 30, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(speedProfile == profile ? Cockpit.live.opacity(0.2) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(speedProfile == profile ? Cockpit.live.opacity(0.45) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speed \(profile.label)")
                    .accessibilityAddTraits(speedProfile == profile ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.05))
            )

            Spacer(minLength: 0)

            cockpitButton(
                icon: isPaused ? "play.fill" : "pause.fill",
                label: isPaused ? "Resume" : "Pause",
                tint: isPaused ? Cockpit.attention : Color.secondary,
                active: isPaused,
                action: onTogglePause
            )
            cockpitButton(
                icon: "forward.end.fill",
                label: "Skip",
                tint: .orange,
                active: false,
                action: onSkip
            )
            cockpitButton(
                icon: "arrow.counterclockwise",
                label: "Retry",
                tint: Cockpit.live,
                active: false,
                action: onRetry
            )
            if let onToggleFreeze {
                cockpitButton(
                    icon: isFrozen ? "play.slash.fill" : "snowflake",
                    label: isFrozen ? "Thaw" : "Freeze",
                    tint: .indigo,
                    active: isFrozen,
                    action: onToggleFreeze
                )
            }
        }
    }

    private func cockpitButton(
        icon: String,
        label: String,
        tint: Color,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(0.2)
            }
            .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(active ? tint.opacity(0.2) : Color.primary.opacity(0.05))
                    .overlay(
                        Capsule().stroke(active ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func currentRow(_ item: RCRQueueItem) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(statusDotColor.opacity(0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusDotColor)
            }
            Text(item.username)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            passwordCountBadge(item.passwordCount)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Cockpit.live.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Cockpit.live.opacity(0.35), lineWidth: 1)
                )
        )
        .shadow(color: Cockpit.live.opacity(isWaitingPulse ? 0.45 : 0.0), radius: 6)
        .scaleEffect(isWaitingPulse ? 1.005 : 1.0)
        .animation(
            isWaitingPulse
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
            value: pulseTrigger
        )
    }

    private func upcomingRow(_ item: RCRQueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 22)
            Text(item.username)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            passwordCountBadge(item.passwordCount)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func completedRow(_ item: RCRQueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .frame(width: 22)
            Text(item.username)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            passwordCountBadge(item.passwordCount, dim: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(0.55)
    }

    private func passwordCountBadge(_ count: Int, dim: Bool = false) -> some View {
        Text("\(count) pw")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(Cockpit.live))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(dim ? Color.secondary.opacity(0.12) : Cockpit.live.opacity(0.18))
            )
    }
}

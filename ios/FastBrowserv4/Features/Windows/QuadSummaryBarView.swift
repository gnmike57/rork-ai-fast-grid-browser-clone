import SwiftUI

/// Compact progress summary shown for the 6-, 8-, 9-, 12-, and 16-window grids instead of
/// a full stack of per-window cards. Tapping it expands into the detailed
/// per-window view (see `BrowserView.quadSummarySection`). Also hosts the
/// grid cockpit: pause-all, resume-all, and a per-window freeze menu.
struct QuadSummaryBarView: View {
    struct LaneSummary: Identifiable {
        let id: Int
        let label: String
        let doneCount: Int
        let currentUsername: String
        let statusColorA: Color
        let statusColorB: Color
    }

    /// One grid window for the freeze menu.
    struct FreezeItem: Identifiable {
        let id: String      // session id, e.g. "S3"
        let isFrozen: Bool
    }

    let isDual: Bool
    let overallCompleted: Int
    let overallTotal: Int
    let overallSuccess: Int
    let anyRunning: Bool
    let lanes: [LaneSummary]

    // MARK: - Grid cockpit

    var isPausedAll: Bool = false
    var onTogglePauseAll: () -> Void = {}
    var freezeItems: [FreezeItem] = []
    var onToggleFreeze: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isPausedAll ? Cockpit.attention : (anyRunning ? Cockpit.live : Cockpit.textTertiary))
                    .frame(width: 8, height: 8)
                Text(isDual ? "Dual RCR" : "RCR")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Cockpit.live)
                    .kerning(0.5)
                Text("\(min(overallCompleted, overallTotal)) / \(overallTotal) · \(overallSuccess) hits")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if anyRunning || isPausedAll {
                    Button(action: onTogglePauseAll) {
                        Image(systemName: isPausedAll ? "play.fill" : "pause.fill")
                            .font(.caption.bold())
                            .foregroundStyle(isPausedAll ? AnyShapeStyle(Cockpit.attention) : AnyShapeStyle(.secondary))
                            .frame(width: 30, height: 26)
                            .background(Capsule().fill(isPausedAll ? Cockpit.attention.opacity(0.2) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPausedAll ? "Resume all windows" : "Pause all windows")
                }
                if !freezeItems.isEmpty {
                    Menu {
                        ForEach(freezeItems) { item in
                            Button {
                                onToggleFreeze(item.id)
                            } label: {
                                Label(
                                    item.isFrozen ? "\(item.id) · frozen" : "\(item.id) · running",
                                    systemImage: item.isFrozen ? "play.slash.fill" : "snowflake"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: freezeItems.contains(where: { $0.isFrozen }) ? "snowflake" : "snowflake.circle")
                            .font(.caption.bold())
                            .foregroundStyle(
                                freezeItems.contains(where: { $0.isFrozen })
                                    ? AnyShapeStyle(Color.indigo)
                                    : AnyShapeStyle(.secondary)
                            )
                            .frame(width: 30, height: 26)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .accessibilityLabel("Freeze windows")
                }
                Text("Expand")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Cockpit.live)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(Cockpit.live)
            }

            if isDual && !lanes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lanes) { lane in
                            laneChip(lane)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private func laneChip(_ lane: LaneSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(lane.statusColorA).frame(width: 6, height: 6)
                Circle().fill(lane.statusColorB).frame(width: 6, height: 6)
                Text(lane.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
            }
            Text(lane.currentUsername.isEmpty ? "—" : lane.currentUsername)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 84, alignment: .leading)
            Text("\(lane.doneCount) done")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Cockpit.live)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Cockpit.live.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Cockpit.live.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}

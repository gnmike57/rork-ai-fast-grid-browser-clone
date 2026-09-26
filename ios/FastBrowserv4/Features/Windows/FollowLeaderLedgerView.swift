import SwiftUI

/// The sync ledger: every mirrored action, newest first, with one cell per
/// window showing what that window did with it.
///
/// This screen is the receipt for the word "unbreakable". A row that is still
/// waiting shows pulsing dots; a row that had to be rebuilt carries an amber
/// marker; a window that left the squad greys out for everything after it.
struct FollowLeaderLedgerView: View {
    let controller: QuadController

    @Environment(\.dismiss) private var dismiss
    @State private var filter: FollowLeaderLedgerFilter = .all

    private var rows: [FollowLeaderLedgerEntry] {
        controller.followLeaderLedger.entries
            .reversed()
            .filter { filter.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Cockpit.hairline)
            content
            filterBar
        }
        .background(Cockpit.canvas.ignoresSafeArea())
        .navigationTitle("Sync Ledger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Cockpit.live)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Cockpit.Space.tight) {
            HStack(spacing: Cockpit.Space.tight) {
                Image(systemName: controller.followLeaderMode.iconName)
                    .font(.caption.bold())
                    .foregroundStyle(Cockpit.live)
                Text(controller.followLeaderMode.label)
                    .font(.cockpitHeading)
                    .foregroundStyle(Cockpit.textPrimary)
                Spacer(minLength: Cockpit.Space.tight)
                if controller.isFollowLeaderGateHolding {
                    Text("HOLDING \(controller.followLeaderGateWaiting)")
                        .font(.cockpitChip)
                        .foregroundStyle(Cockpit.onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Cockpit.live))
                }
            }
            Text(legend)
                .font(.cockpitCaption)
                .foregroundStyle(Cockpit.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Cockpit.Space.base)
        .padding(.vertical, Cockpit.Space.snug)
    }

    private var legend: String {
        let ledger = controller.followLeaderLedger
        if ledger.isEmpty {
            return controller.followLeaderMode.isStrict
                ? "Nothing copied yet. Every action you take in the leader will appear here."
                : "The ledger only records in Unbreakable mode."
        }
        var parts: [String] = ["\(ledger.count) action\(ledger.count == 1 ? "" : "s")"]
        if ledger.waitingCount > 0 { parts.append("\(ledger.waitingCount) waiting") }
        if ledger.repairedCount > 0 { parts.append("\(ledger.repairedCount) repaired") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rows

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: Cockpit.Space.tight) {
                    ForEach(rows) { entry in
                        LedgerRow(entry: entry)
                    }
                }
                .padding(.horizontal, Cockpit.Space.base)
                .padding(.vertical, Cockpit.Space.snug)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Cockpit.Space.snug) {
            Image(systemName: filter == .all ? "list.bullet.rectangle" : "line.3.horizontal.decrease")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Cockpit.textTertiary)
            Text(filter == .all ? "No actions yet" : "Nothing \(filter.label.lowercased())")
                .font(.cockpitHeading)
                .foregroundStyle(Cockpit.textSecondary)
            if filter == .all && !controller.followLeaderMode.isStrict {
                Text("Switch to Unbreakable to record every action.")
                    .font(.cockpitCaption)
                    .foregroundStyle(Cockpit.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Cockpit.Space.section)
    }

    // MARK: - Filters

    private var filterBar: some View {
        HStack(spacing: Cockpit.Space.tight) {
            ForEach(FollowLeaderLedgerFilter.allCases) { option in
                let isSelected = filter == option
                Button {
                    withAnimation(Cockpit.Motion.quick) { filter = option }
                } label: {
                    Text(option.label)
                        .font(.cockpitChip)
                        .foregroundStyle(isSelected ? Cockpit.onAccent : Cockpit.textSecondary)
                        .padding(.horizontal, Cockpit.Space.snug)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(isSelected ? Cockpit.live : Cockpit.surfaceRaised)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Cockpit.Space.base)
        .padding(.top, Cockpit.Space.tight)
        .padding(.bottom, Cockpit.Space.snug)
        .background(Cockpit.surface.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(Cockpit.hairline).frame(height: 1)
        }
    }
}

/// One action, with a cell per window.
private struct LedgerRow: View {
    let entry: FollowLeaderLedgerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Cockpit.Space.tight) {
            HStack(spacing: Cockpit.Space.tight) {
                Image(systemName: iconName)
                    .font(.caption.bold())
                    .foregroundStyle(entry.isCommit ? Cockpit.live : Cockpit.textTertiary)
                    .frame(width: 18)
                Text(entry.summary)
                    .font(.cockpitBody.weight(.semibold))
                    .foregroundStyle(Cockpit.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Cockpit.Space.hair)
                if entry.isCommit {
                    Text("COMMIT")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(Cockpit.live)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Cockpit.live.opacity(0.16)))
                }
            }
            HStack(spacing: Cockpit.Space.hair + 2) {
                ForEach(entry.windowOrder, id: \.self) { window in
                    WindowCell(
                        window: window,
                        state: entry.states[window] ?? .pending,
                        rippleStep: entry.windowOrder.firstIndex(of: window) ?? 0
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Cockpit.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: Cockpit.Radius.medium, style: .continuous)
                .fill(Cockpit.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Cockpit.Radius.medium, style: .continuous)
                .strokeBorder(
                    entry.hasRepair ? Cockpit.attention.opacity(0.5) : Cockpit.hairline,
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        switch entry.kind {
        case .input: return "character.cursor.ibeam"
        case .select: return "chevron.up.chevron.down"
        case .check: return "checkmark.square"
        case .click: return "hand.tap"
        case .submit: return "paperplane.fill"
        case .key: return "keyboard"
        case .scroll: return "arrow.up.and.down"
        case .focus: return "scope"
        case .blur: return "arrow.turn.down.right"
        case .hover: return "cursorarrow.rays"
        }
    }

    private var accessibilityLabel: String {
        let confirmed = entry.states.values.filter { $0 == .confirmed || $0 == .delivered }.count
        return "\(entry.summary). \(confirmed) of \(entry.states.count) windows done."
            + (entry.hasRepair ? " One window was repaired." : "")
    }
}

/// One window's result for one action.
private struct WindowCell: View {
    let window: Int
    let state: FollowLeaderLedgerEntry.WindowState
    /// Position in the row, used to stagger the tick so a healthy squad
    /// visibly ripples left to right instead of snapping all at once.
    let rippleStep: Int

    @State private var hasLanded: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            glyph
            Text("\(window + 1)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Cockpit.textTertiary)
        }
        .frame(width: 22)
        .opacity(state == .dropped ? 0.35 : 1)
        .scaleEffect(hasLanded ? 1 : 0.7)
        .onAppear { land() }
        .onChange(of: state) { _, _ in
            hasLanded = false
            land()
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .pending:
            Circle()
                .fill(Cockpit.textTertiary)
                .frame(width: 9, height: 9)
                .modifier(PendingPulse())
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Cockpit.live)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Cockpit.textSecondary)
        case .repaired:
            Image(systemName: "wrench.adjustable.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Cockpit.attention)
        case .missed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Cockpit.attention)
        case .dropped:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Cockpit.danger)
        }
    }

    private func land() {
        let delay = min(0.18, Double(rippleStep) * 0.022)
        withAnimation(Cockpit.Motion.quick.delay(delay)) { hasLanded = true }
    }
}

/// The slow breath on a window that has not settled yet.
private struct PendingPulse: ViewModifier {
    @State private var isBright: Bool = false

    func body(content: Content) -> some View {
        content
            .opacity(isBright ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isBright)
            .onAppear { isBright = true }
    }
}

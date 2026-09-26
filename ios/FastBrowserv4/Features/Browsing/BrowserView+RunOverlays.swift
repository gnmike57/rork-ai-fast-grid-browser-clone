import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import WebKit

/// Live run progress: the single-window queue pill, and the grid's summary
/// bar with its expandable stack of per-window pills.
///
/// Split out of `BrowserView` because it is a self-contained readout — none
/// of it decides layout, it only reports what the run is doing.

extension BrowserView {

    // MARK: - Single queue pill

    /// Display state for the single-window run — pause outranks whatever the
    /// run was doing when it stopped, exactly as it does on a grid window.
    private var singleRunStatus: RunStatusStyle {
        viewModel.isRCRPaused ? .paused : viewModel.rcrStatus.runStyle
    }

    var singleQueuePill: some View {
        QueuePillView(
            title: "RCR",
            titleColor: Cockpit.live,
            statusDotColor: singleRunStatus.color,
            statusLabel: singleRunStatus.label,
            isWaitingPulse: !viewModel.isRCRPaused
                && (viewModel.rcrStatus == .waiting || viewModel.rcrStatus == .filling),
            total: viewModel.rcrTotal,
            completedCount: viewModel.rcrCompletedIDs.count,
            upcoming: viewModel.queueSnapshot(upcomingLimit: 8),
            completed: viewModel.completedSnapshot(),
            pulseTrigger: viewModel.rcrIndex,
            onViewResults: {
                viewModel.presentedSheet = .results
            },
            speedProfile: viewModel.runSpeedProfile,
            onSpeedChange: { viewModel.setRunSpeedProfile($0) },
            isPaused: viewModel.isRCRPaused,
            onTogglePause: { viewModel.toggleRCRPause() },
            onSkip: { viewModel.skipCurrentCredential() },
            onRetry: { viewModel.retryCurrentPassword() }
        )
    }

    // MARK: - Quad pills

    /// Progress data behind the compact summary bar used by larger grids.
    private var quadOverallStats: (completed: Int, total: Int, success: Int) {
        let active = viewModel.quadController.activeSessions
        let success = active.reduce(0) { $0 + $1.rcrSuccessCount }
        if viewModel.isDualQuadMode {
            // Sum every lane pair's completed/total — using only the first
            // session's queue showed just one pair's progress.
            let progress = viewModel.quadController.dualOverallProgress
            return (progress.completed, progress.total, success)
        }
        return (
            active.reduce(0) { $0 + $1.rcrCompletedIDs.count },
            active.reduce(0) { $0 + $1.rcrTotal },
            success
        )
    }

    private var quadLaneSummaries: [QuadSummaryBarView.LaneSummary] {
        guard viewModel.isDualQuadMode else { return [] }
        let controller = viewModel.quadController
        let laneCount = controller.laneCount > 0 ? controller.laneCount : controller.enabledSessions.count / 2
        return (0..<laneCount).map { lane in
            let (sessionA, sessionB) = controller.lanePair(lane)
            let done = controller.laneCompletedCounts.indices.contains(lane) ? controller.laneCompletedCounts[lane] : 0
            return QuadSummaryBarView.LaneSummary(
                id: lane,
                label: "Pair \(lane + 1)",
                doneCount: done,
                currentUsername: sessionA.rcrCurrentUsername,
                statusColorA: sessionA.rcrStatus.runStyle.color,
                statusColorB: sessionB.rcrStatus.runStyle.color
            )
        }
    }

    /// The 4-window grid always shows the full per-window pill stack. Larger
    /// grids show a compact summary bar that expands into the same detailed
    /// stack on tap.
    @ViewBuilder
    var quadSummarySection: some View {
        if viewModel.quadController.gridSize == .four {
            quadQueuePills
        } else if isQuadDetailExpanded {
            VStack(spacing: 6) {
                collapseSummaryButton
                ScrollView {
                    quadQueuePills
                }
                .frame(maxHeight: 340)
            }
        } else {
            QuadSummaryBarView(
                isDual: viewModel.isDualQuadMode,
                overallCompleted: quadOverallStats.completed,
                overallTotal: quadOverallStats.total,
                overallSuccess: quadOverallStats.success,
                anyRunning: viewModel.quadController.anyRCRRunning,
                lanes: quadLaneSummaries,
                isPausedAll: viewModel.quadController.isQuadRCRPaused,
                onTogglePauseAll: { viewModel.quadController.toggleQuadRCRPause() },
                freezeItems: viewModel.quadController.enabledSessions.map {
                    QuadSummaryBarView.FreezeItem(id: $0.id, isFrozen: $0.isRCRFrozen)
                },
                onToggleFreeze: { id in
                    guard let session = viewModel.quadController.sessions.first(where: { $0.id == id }) else { return }
                    viewModel.quadController.toggleSessionFrozen(session)
                }
            )
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isQuadDetailExpanded = true
                }
            }
        }
    }

    private var collapseSummaryButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isQuadDetailExpanded = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                Text("Collapse")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(Cockpit.live)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(Cockpit.live).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
    }

    private var quadQueuePills: some View {
        VStack(spacing: 4) {
            ForEach(Array(viewModel.quadController.activeSessions.enumerated()), id: \.element.id) { idx, session in
                SwipeToHide(
                    isVisible: Binding(
                        get: { !(quadPillsHidden.indices.contains(idx) ? quadPillsHidden[idx] : false) },
                        set: { newValue in
                            if quadPillsHidden.indices.contains(idx) { quadPillsHidden[idx] = !newValue }
                        }
                    ),
                    edge: .bottom,
                    restore: .labelled(session.id),
                    accessibilityLabel: "Show \(session.id)"
                ) {
                    QueuePillView(
                        title: viewModel.isDualQuadMode ? "\(session.id) · \(session.targetSiteIndex == 0 ? "A" : "B")" : session.id,
                        titleColor: Cockpit.live,
                        statusDotColor: session.displayStatus(
                            isPausedAll: viewModel.quadController.isQuadRCRPaused
                        ).color,
                        statusLabel: session.displayStatus(
                            isPausedAll: viewModel.quadController.isQuadRCRPaused
                        ).label,
                        isWaitingPulse: !session.isRCRFrozen
                            && !viewModel.quadController.isQuadRCRPaused
                            && (session.rcrStatus == .waiting || session.rcrStatus == .filling),
                        total: session.rcrTotal,
                        completedCount: session.rcrCompletedIDs.count,
                        upcoming: viewModel.quadController.queueSnapshot(for: session, upcomingLimit: 4),
                        completed: viewModel.quadController.completedSnapshot(for: session),
                        pulseTrigger: session.rcrIndex,
                        onViewResults: {
                            viewModel.presentedSheet = .results
                        },
                        speedProfile: viewModel.runSpeedProfile,
                        onSpeedChange: { viewModel.setRunSpeedProfile($0) },
                        isPaused: viewModel.quadController.isQuadRCRPaused,
                        onTogglePause: { viewModel.quadController.toggleQuadRCRPause() },
                        onSkip: { viewModel.quadController.skipCurrentForSession(session) },
                        onRetry: { viewModel.quadController.retryCurrentForSession(session) },
                        isFrozen: session.isRCRFrozen,
                        onToggleFreeze: { viewModel.quadController.toggleSessionFrozen(session) }
                    )
                }
            }
        }
    }
}

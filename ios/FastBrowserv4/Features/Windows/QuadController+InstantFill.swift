import Foundation
import WebKit
import os

/// Instant Fill: one reading of the leader, written into every follower at
/// once.
///
/// Follow the Leader mirrors what you *do*, action by action, from the moment
/// it is switched on. Instant Fill answers the other question — you already
/// filled this form in the leader, by hand or by autofill or before the mode
/// was even armed, and you want the same thing in every other window now. So
/// this is a snapshot: read once, write once, no queue and no replay.
///
/// It deliberately does not submit anything. Filling a form and committing it
/// are two different decisions, and only one of them belongs to a fill button.
extension QuadController {

    private static let instantFillLog = Logger(subsystem: "com.fastfill.browser", category: "InstantFill")

    /// True when a fill has a leader to read and at least one window to write
    /// to. Drives whether the chip is offered at all.
    var canInstantFill: Bool {
        isFollowLeaderEnabled
            && leaderWindow?.webView != nil
            && !followLeaderSquad.isEmpty
    }

    /// The window Instant Fill reads from — the same leader the mirroring
    /// engine uses, so the chip can never copy from a different window than
    /// the one filling the screen.
    private var leaderWindow: QuadSession? {
        guard let index = followLeaderIndex else { return nil }
        return sessions.first { $0.index == index }
    }

    /// Reads the leader, then writes what it found into every follower.
    ///
    /// Followers are filled concurrently rather than in turn: a sixteen-window
    /// grid filled serially would wait out fifteen page round-trips, and each
    /// fill is already bounded by its own timeout so one wedged web process
    /// cannot hold up the rest.
    @discardableResult
    func instantFillFromLeader() async -> InstantFillSummary {
        var summary = InstantFillSummary()
        guard isFollowLeaderEnabled, let leader = leaderWindow, let leaderView = leader.webView else {
            return summary
        }
        let squad = followLeaderSquad
        guard !squad.isEmpty else { return summary }

        let snapshot = await auditLeader(in: leaderView)
        summary.sourceFields = snapshot.fields.count
        summary.leaderScanned = snapshot.scanned
        guard !snapshot.isEmpty else {
            Self.instantFillLog.info("audit found nothing to copy (scanned \(snapshot.scanned))")
            return summary
        }
        Self.instantFillLog.info(
            "audit captured \(snapshot.fields.count) field(s) from \(leader.id, privacy: .public)"
        )

        // Resolve every window's card before the fills start. Reading the
        // wallet once here keeps all of them on one consistent assignment even
        // if the vault changes mid-fill.
        let rotating = CardVault.shared.mode == .rotate && snapshot.containsCardFields
        var payloads: [Int: CardFillPayload] = [:]
        if rotating {
            for follower in squad {
                payloads[follower.index] = assignedCardPayload(for: follower)
            }
        }

        let timeout = activeSpeedProfile.followLeaderActionTimeout.seconds
        var running: [Task<(Int, InstantFillOutcome), Never>] = []
        for follower in squad {
            let index = follower.index
            // In rotate mode each window types its own card, never the
            // leader's digits — number, expiry, security code and name
            // swapped together so no window ends up with one card's number
            // and another's expiry.
            let windowSnapshot = rotating
                ? snapshot.substitutingCard(payloads[index])
                : snapshot
            running.append(Task { @MainActor [weak self] in
                guard let self,
                      let target = self.sessions.first(where: { $0.index == index }),
                      let webView = target.webView else {
                    return (index, InstantFillOutcome(reason: "no-webview"))
                }
                let outcome = await Self.applySnapshot(windowSnapshot, in: webView, timeout: timeout)
                return (index, outcome)
            })
        }

        for task in running {
            let (index, outcome) = await task.value
            summary.windows += 1
            summary.filled += outcome.filled
            summary.missed += outcome.missed
            if outcome.filled > 0 { summary.windowsFilled += 1 }
            guard let session = sessions.first(where: { $0.index == index }) else { continue }
            if outcome.filled > 0 {
                // Reuse the card flash: a window quietly gaining values is
                // otherwise completely silent, and a grid-wide fill with no
                // per-window feedback says nothing about where it landed.
                session.cardFillPulse &+= 1
                if rotating, let last4 = payloads[index]?.record.last4 {
                    session.cardLast4 = last4
                }
            }
            if !outcome.reason.isEmpty {
                Self.instantFillLog.info(
                    "\(session.id, privacy: .public) \(outcome.reason, privacy: .public)"
                )
            }
        }

        Self.instantFillLog.info(
            "filled \(summary.filled) field(s) across \(summary.windowsFilled) window(s)"
        )
        return summary
    }

    /// Runs a fill and reports the result, for the chip to call directly.
    func runInstantFill() {
        guard canInstantFill else {
            browserViewModel?.showToast("Nothing to fill from yet", force: true)
            return
        }
        guard !isInstantFilling else { return }
        isInstantFilling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isInstantFilling = false }
            let summary = await self.instantFillFromLeader()
            self.browserViewModel?.showToast(summary.toastMessage, force: true)
        }
    }

    // MARK: - Injected passes

    /// Reads every filled control in the leader.
    private func auditLeader(in webView: WKWebView) async -> InstantFillSnapshot {
        let timeout = activeSpeedProfile.followLeaderActionTimeout.seconds
        return await withCheckedContinuation { (continuation: CheckedContinuation<InstantFillSnapshot, Never>) in
            let box = InstantFillCallBox<InstantFillSnapshot>()
            let settle: @MainActor (InstantFillSnapshot) -> Void = { value in
                guard !box.isSettled else { return }
                box.isSettled = true
                box.watchdog?.cancel()
                box.watchdog = nil
                continuation.resume(returning: value)
            }
            box.watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                settle(InstantFillSnapshot())
            }
            webView.callAsyncJavaScript(
                JavaScriptInjectionService.instantFillAuditBody(),
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    settle(InstantFillSnapshot(jsResult: value))
                case .failure:
                    settle(InstantFillSnapshot())
                }
            }
        }
    }

    /// Writes one snapshot into one window.
    ///
    /// `static` so it can be awaited from a detached fill task without
    /// re-entering the controller, and bounded by a hard timeout so a wedged
    /// web process is abandoned rather than stalling the whole grid's fill.
    private static func applySnapshot(
        _ snapshot: InstantFillSnapshot,
        in webView: WKWebView,
        timeout: TimeInterval
    ) async -> InstantFillOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<InstantFillOutcome, Never>) in
            let box = InstantFillCallBox<InstantFillOutcome>()
            let settle: @MainActor (InstantFillOutcome) -> Void = { value in
                guard !box.isSettled else { return }
                box.isSettled = true
                box.watchdog?.cancel()
                box.watchdog = nil
                continuation.resume(returning: value)
            }
            box.watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                settle(InstantFillOutcome(reason: "timeout"))
            }
            webView.callAsyncJavaScript(
                JavaScriptInjectionService.instantFillApplyBody(),
                arguments: ["snapshot": snapshot.jsArguments],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    settle(InstantFillOutcome(jsResult: value))
                case .failure(let error):
                    settle(InstantFillOutcome(reason: "js-error-\((error as NSError).code)"))
                }
            }
        }
    }
}

/// Settle box for one Instant Fill round trip. Puts a hard timeout on a call
/// WebKit may never complete, while guaranteeing a late completion handler can
/// never resume a continuation twice.
@MainActor
private final class InstantFillCallBox<Value> {
    var isSettled: Bool = false
    /// The safety timeout, cancelled the moment a real result arrives so a
    /// completed call leaves nothing sleeping behind it.
    var watchdog: Task<Void, Never>?
}

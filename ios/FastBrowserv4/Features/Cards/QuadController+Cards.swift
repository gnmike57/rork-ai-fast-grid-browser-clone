import Foundation
import WebKit
import os

/// Card autofill across the grid.
///
/// The window order used here is exactly the mirroring order — enabled
/// windows, leader first — so "window one gets the first card" means the same
/// thing in the wallet's window map, in a toolbar fill, and in a Follow the
/// Leader substitution. Deriving all three from one order is what stops the
/// map from quietly lying about where a card will land.
extension QuadController {

    private static let cardLog = Logger(subsystem: "com.fastfill.browser", category: "Cards")

    /// Enabled windows in assignment order. Disabled cells (the 3×3 centre in
    /// dual-site) are absent, so they never consume a card.
    var cardWindowOrder: [QuadSession] { enabledSessions }

    /// The card a specific window will fill, if any.
    func assignedCard(for session: QuadSession) -> CardRecord? {
        guard let position = cardWindowOrder.firstIndex(where: { $0.index == session.index }) else { return nil }
        return CardVault.shared.record(forPosition: position)
    }

    func assignedCardPayload(for session: QuadSession) -> CardFillPayload? {
        guard let record = assignedCard(for: session) else { return nil }
        return CardVault.shared.payload(for: record)
    }

    // MARK: - Filling

    /// Fills every live window with its assigned card.
    ///
    /// - Returns: how many windows were reached and how many card fields the
    ///   pages exposed between them. Both numbers are reported to the user:
    ///   a checkout with nothing to fill has to look different from a
    ///   successful fill, or the button feels broken on the pages where it
    ///   matters most.
    @discardableResult
    func fillCardsInAllWindows() async -> CardFillSummary {
        let targets = cardWindowOrder
        guard !targets.isEmpty else { return CardFillSummary() }
        guard !CardVault.shared.isEmpty else {
            return CardFillSummary(missingCards: targets.count)
        }
        var summary = CardFillSummary()
        // Every window fills at once rather than in turn: a sixteen-window
        // grid filled serially would leave the last tile waiting out fifteen
        // page round-trips. Each fill is already bounded by its own timeout,
        // so one wedged web process can't hold up the rest.
        var running: [Task<CardFillOutcome, Never>] = []
        for session in targets {
            guard let payload = assignedCardPayload(for: session) else {
                summary.missingCards += 1
                continue
            }
            let index = session.index
            running.append(Task { @MainActor [weak self] in
                guard let self,
                      let target = self.sessions.first(where: { $0.index == index }) else {
                    return CardFillOutcome(reason: "no-webview")
                }
                return await self.fillCard(in: target, payload: payload)
            })
        }
        for task in running {
            let outcome = await task.value
            summary.windows += 1
            summary.found += outcome.found
            summary.filled += outcome.filled
            if outcome.didFindFields { summary.windowsWithFields += 1 }
        }
        return summary
    }

    /// Fills one window with its assigned card.
    @discardableResult
    func fillCard(in session: QuadSession) async -> CardFillOutcome {
        guard let payload = assignedCardPayload(for: session) else {
            return CardFillOutcome(reason: "no-card")
        }
        return await fillCard(in: session, payload: payload)
    }

    /// Runs the injected fill inside one window, bounded by a hard timeout so
    /// a wedged web process can never hang the whole grid's fill.
    @discardableResult
    func fillCard(in session: QuadSession, payload: CardFillPayload) async -> CardFillOutcome {
        guard let webView = session.webView else { return CardFillOutcome(reason: "no-webview") }
        let outcome = await CardFillService.fill(
            payload,
            in: webView,
            timeout: activeSpeedProfile.followLeaderActionTimeout.seconds
        )
        if outcome.didFindFields {
            session.cardLast4 = payload.record.last4
            session.cardFillPulse &+= 1
        }
        return outcome
    }

    // MARK: - Auto-fill on checkout

    /// Called when a window finishes loading. With auto-fill armed this fills
    /// the window's card if — and only if — the page actually exposes card
    /// fields; the injected pass reports zero and does nothing otherwise.
    func autoFillCardIfArmed(session s: QuadSession) {
        guard CardVault.shared.isAutoFillArmed, !CardVault.shared.isEmpty else { return }
        guard !s.isDisabled, s.webView != nil else { return }
        let index = s.index
        Task { @MainActor [weak self] in
            // A short settle: card frames on a real checkout mount after the
            // document itself reports done.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self,
                  CardVault.shared.isAutoFillArmed,
                  let session = self.sessions.first(where: { $0.index == index }),
                  !session.isLoading else { return }
            let outcome = await self.fillCard(in: session)
            if outcome.didFindFields {
                Self.cardLog.info("auto-filled \(session.id, privacy: .public) fields=\(outcome.found)")
            }
        }
    }

    // MARK: - Follow the Leader substitution

    /// Rewrites a mirrored action so a rotate-mode follower types its own card
    /// rather than the leader's.
    ///
    /// In same-as-leader mode this is a pass-through: every window is meant to
    /// end up with identical details, and the leader's own keystrokes already
    /// say what those are.
    func cardSubstitutedAction(
        _ action: FollowLeaderAction,
        for follower: QuadSession
    ) -> FollowLeaderAction {
        guard CardVault.shared.mode == .rotate,
              action.kind == .input || action.kind == .select,
              CardFieldKind.classify(hint: action.hint) != nil,
              let payload = assignedCardPayload(for: follower) else { return action }
        let substituted = CardSubstitution.substitute(action, with: payload)
        if substituted.value != action.value {
            follower.cardLast4 = payload.record.last4
        }
        return substituted
    }
}

/// Totals for one grid-wide card fill.
nonisolated struct CardFillSummary: Equatable, Sendable {
    /// Windows the fill actually reached.
    var windows: Int = 0
    /// Windows whose page exposed card fields.
    var windowsWithFields: Int = 0
    /// Card fields seen across every window.
    var found: Int = 0
    /// Fields actually written.
    var filled: Int = 0
    /// Windows skipped because no card could be resolved for them.
    var missingCards: Int = 0

    /// The message shown after a fill. A page with no card fields has to read
    /// differently from a successful fill — silence there is what makes an
    /// autofill button feel broken.
    var toastMessage: String {
        if windows == 0 {
            return missingCards > 0 ? "No card saved yet" : "No windows to fill"
        }
        if windowsWithFields == 0 {
            return "No card fields on this page"
        }
        let windowWord = windowsWithFields == 1 ? "window" : "windows"
        let fieldWord = found == 1 ? "field" : "fields"
        return "Filled \(windowsWithFields) \(windowWord) · \(found) card \(fieldWord)"
    }
}

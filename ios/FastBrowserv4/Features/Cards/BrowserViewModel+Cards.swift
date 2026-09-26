import Foundation
import WebKit

/// Card autofill entry points for the toolbar button.
///
/// Routing lives here rather than in the view so "fill everywhere" means the
/// same thing whichever mode the browser happens to be in: the grid fills every
/// live window, a single window fills itself, and both report back with the
/// same honest summary.
extension BrowserViewModel {

    /// Web view a single-window fill targets — the replayed session while the
    /// deck is up, otherwise the active tab.
    var cardFillWebView: WKWebView? {
        if isReplayMode { return replayTab?.webView }
        return activeTab?.webView
    }

    /// True when a fill has somewhere to go.
    var canFillCards: Bool {
        if CardVault.shared.isEmpty { return false }
        if isQuadMode { return !quadController.cardWindowOrder.isEmpty }
        return cardFillWebView != nil
    }

    /// Fills every live window with its assigned card, then says what happened.
    func fillCardsEverywhere() {
        guard !CardVault.shared.isEmpty else {
            showToast("No card saved yet — add one in Cards", force: true)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summary: CardFillSummary
            if self.isQuadMode {
                summary = await self.quadController.fillCardsInAllWindows()
            } else {
                summary = await self.fillCardInSingleWindow()
            }
            self.showToast(summary.toastMessage, force: true)
        }
    }

    /// Fills only the window currently in focus.
    func fillCardInFocusedWindow() {
        guard !CardVault.shared.isEmpty else {
            showToast("No card saved yet — add one in Cards", force: true)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summary: CardFillSummary
            if self.isQuadMode {
                let session = self.quadController.focusedSession
                let outcome = await self.quadController.fillCard(in: session)
                summary = CardFillSummary(
                    windows: outcome.reason == "no-webview" || outcome.reason == "no-card" ? 0 : 1,
                    windowsWithFields: outcome.didFindFields ? 1 : 0,
                    found: outcome.found,
                    filled: outcome.filled,
                    missingCards: outcome.reason == "no-card" ? 1 : 0
                )
            } else {
                summary = await self.fillCardInSingleWindow()
            }
            self.showToast(summary.toastMessage, force: true)
        }
    }

    /// Advances the rotation by one card and confirms the new leading card, so
    /// the button is useful without opening the wallet.
    func advanceCardRotation() {
        let vault = CardVault.shared
        guard vault.count > 1 else {
            showToast(vault.isEmpty ? "No card saved yet" : "Only one card saved", force: true)
            return
        }
        vault.advanceRotation()
        if let first = vault.record(forPosition: 0) {
            showToast("Now starting at ••\(first.last4)", force: true)
        }
    }

    func setCardFillMode(_ mode: CardFillMode) {
        CardVault.shared.mode = mode
        showToast(mode == .rotate ? "Cards: rotate per window" : "Cards: same as leader", force: true)
    }

    func toggleCardAutoFill() {
        let vault = CardVault.shared
        guard !vault.isEmpty || vault.isAutoFillArmed else {
            showToast("No card saved yet — add one in Cards", force: true)
            return
        }
        vault.isAutoFillArmed.toggle()
        showToast(
            vault.isAutoFillArmed ? "Auto-fill armed for checkouts" : "Auto-fill off",
            force: true
        )
    }

    /// The single-window path: position 0 in the window order is the only
    /// window there is.
    private func fillCardInSingleWindow() async -> CardFillSummary {
        guard let payload = CardVault.shared.payload(forPosition: 0) else {
            return CardFillSummary(missingCards: 1)
        }
        guard let webView = cardFillWebView else {
            return CardFillSummary()
        }
        let outcome = await CardFillService.fill(
            payload,
            in: webView,
            timeout: runSpeedProfile.followLeaderActionTimeout.seconds
        )
        return CardFillSummary(
            windows: 1,
            windowsWithFields: outcome.didFindFields ? 1 : 0,
            found: outcome.found,
            filled: outcome.filled
        )
    }
}

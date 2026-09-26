import Foundation
import WebKit
import os

/// Does the real work behind "clone session from Window 1": captures a donor
/// window's live session, writes it into each target window's isolated store,
/// verifies it actually landed, and controls when each window is allowed to
/// load so a cloned window never boots logged out.
///
/// Cookies are written into the *rendered web view's own* data-store instance
/// whenever one exists. A second `WKWebsiteDataStore(forIdentifier:)` instance
/// is not guaranteed to publish writes into a web view already running on that
/// identity, which is how clones used to disappear.
@MainActor
final class SessionCloneService {
    static let shared = SessionCloneService()
    private static let log = Logger(subsystem: "com.fastfill.browser", category: "SessionClone")
    private init() {}

    /// Outcome of one clone pass.
    struct Report: Sendable {
        /// Window tags that received the session and passed verification.
        var seeded: [String] = []
        /// Window tags whose store did not end up holding the donor's cookies.
        var missed: [String] = []
        /// True when at least one donor window could be captured.
        var hadDonor: Bool = false
        /// True when a donor actually had cookies scoped to the target site.
        var carriedCookies: Bool = false

        var didSeedAnything: Bool { !seeded.isEmpty || !missed.isEmpty }
    }

    /// Bumped per pass so a superseded clone (rapid mode switching) stops
    /// touching windows the newer layout has already re-planned.
    private var generation: Int = 0
    private var holdWatchdog: Task<Void, Never>?
    /// Every window currently held, keyed by window index. Tracked here (not
    /// just on the sessions) so a hold can never be stranded by a layout that
    /// shrinks out from under the pass that placed it.
    private var heldSessions: [Int: QuadSession] = [:]

    /// Longest a window may sit on the restoring-session hold before it is
    /// released anyway — a wedged donor page must never strand the grid.
    private static let holdTimeout: Duration = .seconds(12)

    // MARK: - Load gating

    /// Holds every window's page load until its clone lands. Called before
    /// the layout change navigates the grid, so the windows never issue a
    /// logged-out load in the first place.
    func beginHold(for sessions: [QuadSession], timing: SessionCloneLoadTiming) {
        guard timing == .waitForSession else { return }
        // Disabled cells are held too: the incoming layout may re-enable
        // them, and an unused cell has no web view to strand.
        for session in sessions {
            session.isRestoringSession = true
            heldSessions[session.index] = session
        }
    }

    /// Clears every outstanding hold and lets those windows load. Covers both
    /// the windows this service is tracking and any extras the caller passes,
    /// so a hold survives a layout that changed size mid-pass. Safe to call
    /// when nothing is held.
    func releaseAllHolds(_ sessions: [QuadSession] = [], reason: String) {
        var pending = heldSessions
        for session in sessions where session.isRestoringSession {
            pending[session.index] = session
        }
        heldSessions.removeAll()
        guard !pending.isEmpty else { return }
        Self.log.info("releasing \(pending.count) held window(s) — \(reason, privacy: .public)")
        for session in pending.values.sorted(by: { $0.index < $1.index }) {
            release(session, didSeed: false)
        }
    }

    /// Drops every hold *without* handing those windows a page — used when
    /// the grid is being left entirely, so nothing loads on its way out. Also
    /// supersedes any in-flight pass.
    func cancelHolds(reason: String) {
        holdWatchdog?.cancel()
        holdWatchdog = nil
        guard !heldSessions.isEmpty else { return }
        Self.log.info("cancelling \(self.heldSessions.count) hold(s) — \(reason, privacy: .public)")
        generation &+= 1
        for session in heldSessions.values { session.isRestoringSession = false }
        heldSessions.removeAll()
    }

    // MARK: - Clone

    /// Executes a plan from `SessionCarry.jobs`. Every held window is
    /// released before this returns, seeded or not.
    /// - Parameters:
    ///   - jobs: donor → targets pairs for the settled layout.
    ///   - sessions: every live window in the layout.
    ///   - externalWebView: the single window's web view when the grid is
    ///     being entered from single-window mode.
    func run(
        jobs: [SessionCarry.Job],
        sessions: [QuadSession],
        externalWebView: WKWebView?,
        timing: SessionCloneLoadTiming
    ) async -> Report {
        generation &+= 1
        let pass = generation
        startHoldWatchdog(sessions: sessions, pass: pass)

        let byIndex = Dictionary(uniqueKeysWithValues: sessions.map { ($0.index, $0) })
        var report = Report()

        for job in jobs {
            guard generation == pass else { break }
            guard let donor = donorWebView(for: job.source, byIndex: byIndex, external: externalWebView) else {
                Self.log.info("skipping job — donor \(String(describing: job.source), privacy: .public) has no web view")
                continue
            }
            let snapshot = await SessionTransferService.shared.capture(from: donor)
            report.hadDonor = true

            for targetIndex in job.targetIndices {
                guard generation == pass else { break }
                guard let session = byIndex[targetIndex], !session.isDisabled else { continue }
                if case .window(let donorIndex) = job.source, donorIndex == targetIndex { continue }

                let outcome = await seed(snapshot, into: session, pass: pass)
                if outcome.hadCookies { report.carriedCookies = true }
                if outcome.verified {
                    report.seeded.append(session.sessionTag)
                } else {
                    report.missed.append(session.sessionTag)
                }
            }
        }

        guard generation == pass else { return report }
        holdWatchdog?.cancel()
        holdWatchdog = nil
        releaseAllHolds(sessions, reason: "clone finished")
        Self.log.info("clone pass done — seeded=\(report.seeded.count) missed=\(report.missed.count)")
        return report
    }

    private struct SeedOutcome {
        let verified: Bool
        let hadCookies: Bool
    }

    /// Writes the donor's cookies into one window's store, reads them back to
    /// prove they stuck, then lets that window load.
    private func seed(_ snapshot: SessionSnapshot, into session: QuadSession, pass: Int) async -> SeedOutcome {
        let store = session.webView?.configuration.websiteDataStore
            ?? WKWebsiteDataStore(forIdentifier: session.storeID)
        await SessionTransferService.shared.applyCookies(snapshot, to: store, storeID: session.storeID)

        let host = session.url?.host(percentEncoded: false)
            ?? URL(string: snapshot.href)?.host(percentEncoded: false)
        let expected = SessionTransferService.cookieNames(in: snapshot, matchingHost: host)

        guard !expected.isEmpty else {
            // The donor holds nothing for this site — there is no session to
            // carry, so this window can't be "missing" one, and there is
            // nothing new for it to re-request either.
            finish(session, didSeed: false, pass: pass)
            return SeedOutcome(verified: true, hadCookies: false)
        }

        let present = await SessionTransferService.shared.cookieNames(in: store, matchingHost: host)
        let verified = expected.isSubset(of: present)
        if !verified {
            let lost = expected.subtracting(present).count
            Self.log.error("clone incomplete for \(session.sessionTag, privacy: .public) — \(lost) cookie(s) rejected")
        }
        finish(session, didSeed: true, pass: pass)
        return SeedOutcome(verified: verified, hadCookies: true)
    }

    /// Ends one window's part of a pass. A superseded pass leaves the window
    /// alone — the newer layout owns its hold and will load it itself.
    private func finish(_ session: QuadSession, didSeed: Bool, pass: Int) {
        guard generation == pass else { return }
        release(session, didSeed: didSeed)
    }

    /// Ends a window's hold and gives it the page it should be showing. A
    /// window that already loaded (Load-now timing) is refreshed instead so
    /// it re-requests with the cloned cookies attached.
    private func release(_ session: QuadSession, didSeed: Bool) {
        let wasHolding = session.isRestoringSession
        session.isRestoringSession = false
        heldSessions.removeValue(forKey: session.index)
        // An unused cell (the 3×3 dual-site centre) must never be handed a
        // page just because it was held with the rest of the layout.
        guard !session.isDisabled else { return }
        guard let webView = session.webView else { return }
        if wasHolding {
            guard let url = session.url else { return }
            webView.load(URLRequest(url: url))
        } else if didSeed {
            if webView.url != nil {
                webView.reload()
            } else if let url = session.url {
                webView.load(URLRequest(url: url))
            }
        }
    }

    private func donorWebView(
        for source: SessionCarry.Source,
        byIndex: [Int: QuadSession],
        external: WKWebView?
    ) -> WKWebView? {
        switch source {
        case .external:
            return external
        case .window(let index):
            return byIndex[index]?.webView
        }
    }

    private func startHoldWatchdog(sessions: [QuadSession], pass: Int) {
        holdWatchdog?.cancel()
        holdWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.holdTimeout)
            guard let self, !Task.isCancelled, self.generation == pass else { return }
            // Release the tracked holds *and* anything this pass is covering,
            // so a wedged donor page can never strand the grid.
            self.releaseAllHolds(sessions, reason: "hold timed out")
        }
    }
}

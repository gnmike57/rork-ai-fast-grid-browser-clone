import Foundation
import SwiftUI
import WebKit

/// One of up to sixteen parallel browser sessions used in multi-window mode
/// (grids of 4, 6, 8, 9, 12, or 16). Owns its own WKWebView (with an isolated
/// `WKWebsiteDataStore`) and its own RCR progress so every session can run
/// completely independently of the others.
@Observable
@MainActor
final class QuadSession: Identifiable {
    enum Status: String {
        case idle, navigating, filling, submitting, waiting, burning, success, finished
        /// Dual-quad only: this side finished its result for the current
        /// credential and is waiting on its lane partner (the other URL)
        /// before the pair advances to the next vault entry.
        case pairWait
    }

    let id: String
    let index: Int
    var storeID: UUID
    /// Bumped when this cell adopts a new isolated store so the web view
    /// is recreated against the new cookie jar.
    var webViewGeneration: Int = 0
    /// Browser target assignment. Recalculated from the active layout and
    /// split pattern whenever the grid or dual-site pattern changes.
    var targetSiteIndex: Int
    /// True when this cell is unused in the current layout — e.g. the 3×3
    /// center window in dual-site mode. Disabled cells show an "Unused"
    /// label and are excluded from lane pairing and credential distribution.
    var isDisabled: Bool = false

    var url: URL?
    var title: String = ""
    var isLoading: Bool = false
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    weak var webView: WKWebView?
    /// True when the last navigation failed (offline, DNS, dead host) and
    /// hasn't been retried yet. Drives the "Couldn't load" retry overlay
    /// instead of leaving the tile blank forever.
    var loadFailed: Bool = false
    /// True while this window is holding its page load until a cloned
    /// session lands in its store, so it never boots logged out and then
    /// flips. Set before the layout navigates; cleared by the clone (or by
    /// its watchdog), which then issues the load itself.
    var isRestoringSession: Bool = false

    // RCR state — per session.
    var rcrRunning: Bool = false
    var rcrStatus: Status = .idle
    var rcrIndex: Int = 0
    var rcrTotal: Int = 0
    var rcrCurrentUsername: String = ""
    var rcrCurrentDomain: String = ""
    var rcrTargetURL: URL?
    var rcrSuccessCount: Int = 0
    var rcrBurnFlash: Int = 0

    var rcrQueueIDs: [String] = []
    /// Snapshot of usernames + password counts captured at run start so the
    /// queue pill stays accurate even if the user edits the vault mid-run.
    var rcrQueueUsernames: [String] = []
    var rcrQueuePasswordCounts: [Int] = []
    /// IDs that have reached a terminal state (success / disabled-burned /
    /// exhausted). Drives the "Completed" section of the queue pill.
    var rcrCompletedIDs: Set<String> = []

    var rcrPasswords: [String] = []
    var rcrPasswordIndex: Int = 0
    /// Which credential the in-memory `rcrPasswords` list belongs to.
    /// Guards against the cross-credential bug where a parked run handed
    /// the next credential the previous one's password list.
    var rcrPasswordsCredentialID: String = ""
    /// Bumped by skip/retry/stop so in-flight fill legs (extra-submit
    /// loops) can detect they've been superseded and bail out instead of
    /// racing the new attempt.
    var rcrAttemptGeneration: Int = 0
    /// True while this window rests between attempts (freeze control).
    /// Pause-all is separate and lives on the controller.
    var isRCRFrozen: Bool = false
    var rcrAwaitingNavigation: Bool = false
    /// Per-attempt watchdog: fires when a navigation or the post-submit
    /// observation produces no page state within the timeout (dead page,
    /// failed load, wedged web process) so the run advances instead of
    /// stalling in "watching" forever.
    var rcrWatchdog: Task<Void, Never>?
    /// True while the runner is performing the configured extra submits.
    /// All other RCR actions are paused until this clears.
    var rcrExtraSubmitsInFlight: Bool = false
    /// True while the success cascade is capturing / asking the AI.
    var rcrJudging: Bool = false
    /// Set when this window just burned a perm-disabled session. The next
    /// navigation must wait for page boot + cookie consent before filling.
    var needsPostBurnSettle: Bool = false
    /// Latest attributed memory sample for the diagnostic overlay.
    var memorySnapshot: WindowMemorySnapshot?
    /// Latest automated leak-check result for this window.
    var leakCheck: WindowLeakCheckReport = .idle

    // Follow the Leader mirroring state (follower windows only).
    /// True while a mirrored action is being applied + verified in this
    /// window. Drives the "working" indicator in the status strip.
    var flWorking: Bool = false
    /// Count of mirrored actions this window has applied since the mode was
    /// last enabled.
    var flReplayCount: Int = 0
    /// Recent mirrored actions that could not be verified (field never held
    /// the value, or a button/element could not be found) after every retry.
    /// Surfaced as the misfire badge over the full-screen leader.
    ///
    /// Deliberately *recent* rather than lifetime. A window that missed once
    /// and has replayed a hundred actions perfectly since is healthy, and a
    /// badge that can never clear only teaches you to ignore it.
    var flMisfireCount: Int = 0
    /// Consecutive mirrored actions applied without a miss. A miss resets it;
    /// a clean run of them is what lets a stale misfire badge clear itself.
    var flCleanStreak: Int = 0
    /// How many leader actions are still queued for this window. Non-zero
    /// means it is behind; the chip shows the backlog.
    var flPending: Int = 0
    /// True while this window is holding a mirrored action back because its
    /// page is still loading — distinct from "working" so the chip can say
    /// "waiting to load" rather than implying a stall.
    var flAwaitingLoad: Bool = false
    /// Times this window was quietly pulled back onto the leader's page
    /// after drifting (redirect, popup, tap that went somewhere else).
    ///
    /// Budgeted per page, not per session: the allowance refills when the
    /// leader commits a genuinely new document, so a window that struggled on
    /// the sign-in page is not abandoned for the whole checkout after it.
    var flResyncCount: Int = 0
    /// Bumped every time this window drains its queue and is fully caught up
    /// with the leader. Drives the chip's catch-up pulse.
    var flSyncPulse: Int = 0
    /// True from the moment this window's web content process dies until its
    /// replacement commits a document. Mirrored actions are held rather than
    /// fired into a dead process — without this every queued action burned
    /// three attempts and a full timeout before being counted as a miss.
    var flRecovering: Bool = false
    /// How many times this window's web process has been recovered. Surfaced
    /// on the chip so a window the system keeps killing is visible instead of
    /// looking merely slow.
    var flCrashCount: Int = 0
    /// Unbreakable only: true while this window is being repaired — reloading
    /// the leader's page so it can replay it from the start. Distinct from
    /// `flAwaitingLoad`, which is an ordinary page wait.
    var flRepairing: Bool = false
    /// Times this window has been repaired since the mode was enabled. Capped:
    /// a window that needs repairing over and over is not recoverable, it is
    /// broken, and it is dropped instead of repaired forever.
    var flRepairCount: Int = 0
    /// The action this window was last repaired for. If the very same action
    /// misses again after a full page replay, the repair itself has failed —
    /// which is what makes the ladder terminate instead of looping.
    var flRepairSeq: Int = -1
    /// Unbreakable only: this window could not be kept in exact sync and has
    /// left the squad. It keeps browsing where it is; it just stops receiving
    /// mirrored actions, so the windows that remain stay perfectly in step.
    var flDropped: Bool = false

    // Card autofill state.
    /// Last four digits of the card this window most recently filled — or
    /// substituted into a mirrored action. Shown on the follower chip so it is
    /// always obvious which card went where.
    var cardLast4: String = ""
    /// Bumped on every completed card fill, driving the tile's fill flash.
    var cardFillPulse: Int = 0

    init(index: Int) {
        self.index = index
        self.id = "S\(index + 1)"
        self.storeID = QuadDataStore.identifier(for: index)
        self.targetSiteIndex = index % 2
    }

    /// Hands this cell a brand-new isolated store. The previous store is
    /// left untouched — callers park or burn it themselves.
    func adoptFreshStore() {
        storeID = UUID()
        webViewGeneration += 1
        webView = nil
    }

    var sessionTag: String { id }

    var displayURL: String { url?.absoluteString ?? "" }

    var domain: String {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

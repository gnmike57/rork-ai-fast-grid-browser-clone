import Foundation
import SwiftData
import SwiftUI
import UIKit
import WebKit
import os

/// Owns up to sixteen `QuadSession` objects and orchestrates multi-window
/// browsing across whichever grid size is currently active (4, 6, 8, 9, 12,
/// or 16 windows). Sessions beyond `activeCount` sit dormant — no WKWebView is
/// created for them until their cell is actually rendered.
@Observable
@MainActor
final class QuadController {
    private static let followLeaderLog = Logger(subsystem: "com.fastfill.browser", category: "FollowLeader")

    /// All possible sessions, pre-allocated up to the largest grid (16).
    let sessions: [QuadSession]

    // MARK: - Dual-site lane state
    //
    // Stored here rather than in QuadController+DualSite.swift because a
    // Swift extension cannot hold stored properties, and the extension
    // lives in another file so these have to stay visible to it.
    struct LaneState {
        var credentials: [Credential] = []
        /// Credentials already finished against both target sites when this
        /// run (re)started. Skipped during assignment; their completed count
        /// was backfilled at start so pause→resume keeps the display honest.
        var skipIDs: Set<String> = []
        var index: Int = 0
        var resultA: AttemptRecord.Status?
        var resultB: AttemptRecord.Status?
        var finalizing: Bool = false
    }

    var dualQuadActive: Bool = false
    var dualQuadURLA: URL?
    var dualQuadURLB: URL?
    var dualQuadTargetDomainA: String = ""
    var dualQuadTargetDomainB: String = ""
    var laneStates: [LaneState] = []
    /// Dynamic lane→session mapping, rebuilt from the active split pattern
    /// so that horizontal, vertical, and checkerboard distributions each
    /// pair the correct A-side and B-side sessions together.
    var laneSessionAIndices: [Int] = []
    var laneSessionBIndices: [Int] = []
    /// True when a session's side hit a permanent "been disabled" and needs
    /// its isolated data store burned + the login page reloaded (with a
    /// cookie-notice wait) before the lane's next credential is attempted.
    var dualNeedsBurn: [Int: Bool] = [:]
    var dualCredentialIDBySessionIndex: [Int: String] = [:]

    var focusedIndex: Int = 0
    /// The grid size currently in use. Call `setGridSize(_:)` so dual-site
    /// target assignments are recalculated whenever the window count changes.
    private(set) var gridSize: WindowGridSize = .four
    var activeCount: Int { gridSize.rawValue }
    /// The sessions actually shown/used by the current grid size.
    var activeSessions: [QuadSession] { Array(sessions.prefix(activeCount)) }
    /// Active sessions that are not disabled (e.g. 3×3 center in dual-site).
    var enabledSessions: [QuadSession] { activeSessions.filter { !$0.isDisabled } }

    var anyRCRRunning: Bool {
        enabledSessions.contains { $0.rcrRunning }
    }
    /// When `true`, sessions retry passwords that previously came back as
    /// `failed`. `success` and `disabled` results are always skipped.
    var retryFailed: Bool = false
    /// True while every window rests between attempts (pause-all).
    private(set) var isQuadRCRPaused: Bool = false
    /// One continuation per frozen window index, resolved on thaw.
    private var freezeContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Every window suspended by pause-all — pause-all suspends multiple
    /// runners at once, so one continuation per waiting window.
    private var quadPauseContinuations: [CheckedContinuation<Void, Never>] = []
    /// Per-lane completed-credential counters for dual-site mode, sized to
    /// the active lane count whenever a dual-site run starts. Powers the
    /// compact summary bar shown on the larger grids.
    var laneCompletedCounts: [Int] = []

    weak var browserViewModel: BrowserViewModel?
    /// Read-only access for multi-window UI (address bar sync, etc.).
    var hostBrowser: BrowserViewModel? { browserViewModel }
    var modelContext: ModelContext?

    /// Re-entrancy latch: set synchronously at run start, before the
    /// off-main keychain preflight completes, so a double-tap can't stack
    /// two overlapping runs. Cleared when the run begins or is stopped.
    var isStartingRCR: Bool = false
    /// Generation guard: a stop followed by a quick restart invalidates the
    /// previous preflight task, so its continuation can't start a stale run.
    var rcrStartGeneration: Int = 0
    private var dualSiteURLA: URL?
    private var dualSiteURLB: URL?
    private(set) var dualSiteSplitPattern: DualSiteSplitPattern = .checkerboard
    private(set) var isDualTargetMode: Bool = false

    // MARK: - Follow the Leader
    /// When on, actions in the first window (the Leader) are mirrored onto
    /// every other window. Each follower drains its own ordered queue
    /// concurrently, so a big grid keeps pace instead of cascading.
    private(set) var isFollowLeaderEnabled: Bool = false
    /// Pending staggered navigation tasks (shared URL bar, back/forward,
    /// reload, drift resync), cancelled on disable/mode change.
    private var followLeaderTasks: [Task<Void, Never>] = []
    /// Bumped on disable so in-flight replays that already passed their
    /// cancellation check still bail before touching a follower.
    private var followLeaderGeneration: Int = 0
    /// One ordered backlog of mirrored actions per follower window index.
    private var followLeaderQueues: [Int: FollowLeaderQueue] = [:]
    /// The single in-flight drain task per follower. Its existence is what
    /// guarantees a window never applies two actions at once — which is how
    /// typing used to land after the submit it was meant to precede.
    private var followLeaderPumps: [Int: Task<Void, Never>] = [:]
    /// Monotonic sequence stamped on each recorded action.
    private var followLeaderSeq: Int = 0
    /// Last drift-resync per follower, so a site that legitimately redirects
    /// can never trap a window in a reload loop.
    private var followLeaderResyncAt: [Int: ContinuousClock.Instant] = [:]
    /// Normalized key of the page the leader last committed. Used to tell a
    /// genuinely new document from a reload of the same one, which decides
    /// whether the per-page drift allowance refills.
    private var leaderPageKey: String?

    /// How faithfully the leader is copied — Relaxed (best effort, merges
    /// typing) or Unbreakable (everything, exactly, confirmed).
    private(set) var followLeaderMode: FollowLeaderSyncMode = .saved
    /// Every mirrored action and what each window did with it. Unbreakable
    /// only: a claim of exactness that cannot be inspected is just a hope.
    private(set) var followLeaderLedger = FollowLeaderLedger()
    /// Every action recorded on the leader's *current* page, in order. This
    /// is what a repair replays to rebuild a window that fell out of step,
    /// so it is cleared the moment the leader commits a new document.
    private var followLeaderPageJournal: [FollowLeaderAction] = []
    /// The in-flight commit hold, if any.
    private var followLeaderGateTask: Task<Void, Never>?
    /// Windows the leader is currently held waiting for. Zero means nothing
    /// is being held.
    private(set) var followLeaderGateWaiting: Int = 0
    /// Bumped whenever a commit hold releases, so the UI can tap a haptic.
    private(set) var followLeaderGateReleases: Int = 0

    /// Attempts (first try + retries) for one mirrored action before the
    /// window is flagged (Relaxed) or repaired (Unbreakable). Two fast
    /// retries, because the usual cause is a control that had not mounted.
    private static let followLeaderMaxAttempts: Int = 3
    /// Repairs allowed for one window on one page before it is dropped
    /// instead. A window that needs rebuilding over and over is not slow,
    /// it is broken, and pretending otherwise stalls every other window.
    private static let followLeaderMaxRepairs: Int = 3
    /// Ceiling on the repair journal. Entries are tiny, so this is generous
    /// enough that a real flow never reaches it.
    private static let followLeaderJournalCap: Int = 1200
    /// Minimum gap between drift resyncs for the same window.
    private static let followLeaderResyncCooldown: TimeInterval = 8
    /// Drift resyncs allowed per window before it is left where it is.
    /// Budgeted per page — `followLeaderCellDidCommit` refills it whenever the
    /// leader reaches a genuinely new document.
    private static let followLeaderMaxResyncs: Int = 3
    /// Consecutive clean actions that retire a window's misfire flag. Long
    /// enough that a window genuinely struggling keeps its badge, short enough
    /// that one unlucky miss does not brand it for the whole session.
    private static let followLeaderCleanStreakToClear: Int = 8
    /// Settle window before a URL mismatch is treated as real drift rather
    /// than a redirect still in flight.
    private static let followLeaderResyncSettle: Duration = .milliseconds(900)
    /// Longest a window is held in recovery after its web process died. If
    /// the replacement never commits, the hold is released so the queue is
    /// never wedged waiting on a window that is not coming back.
    private static let followLeaderRecoveryHold: Duration = .seconds(12)
    /// True while an Instant Fill is reading the leader and writing every
    /// follower. Latches the chip so an impatient double tap cannot start two
    /// overlapping fills into the same forms.
    var isInstantFilling: Bool = false

    /// How the leader/followers are arranged while the mode is on — Hidden
    /// (followers invisible) or Peek (live follower thumbnails strip). The
    /// status-strip toggle writes through here; the choice is persisted.
    var followLeaderDisplayStyle: FollowLeaderDisplayStyle = .saved {
        didSet {
            guard oldValue != followLeaderDisplayStyle else { return }
            followLeaderDisplayStyle.save()
            Self.followLeaderLog.info("display style → \(self.followLeaderDisplayStyle.rawValue, privacy: .public)")
        }
    }

    init() {
        self.sessions = (0..<QuadDataStore.maxSessionCount).map { QuadSession(index: $0) }
    }

    func setup(modelContext: ModelContext, browser: BrowserViewModel) {
        self.modelContext = modelContext
        self.browserViewModel = browser
        for s in sessions where s.url == nil {
            s.url = BrowserViewModel.defaultHomeURL
        }
    }

    var focusedSession: QuadSession { sessions[focusedIndex] }

    /// Clears any leftover dual-site assignment so the grid behaves as a
    /// single-site grid. Called when the user enters a single-site grid —
    /// including re-picking the same grid size, where `setGridSize`
    /// early-returns and would otherwise leave the dual-site flag stale,
    /// silently blocking Follow the Leader.
    func exitDualSiteMode() {
        guard isDualTargetMode else { return }
        isDualTargetMode = false
        dualSiteURLA = nil
        dualSiteURLB = nil
        for session in activeSessions {
            session.isDisabled = false
            session.targetSiteIndex = 0
        }
        clearDualLaneState()
        refocusIfDisabled()
    }

    /// Forgets every lane pairing and the counters built from it.
    ///
    /// Lane maps are derived from a dual-site assignment, so they describe a
    /// layout that no longer exists the moment that assignment is dropped.
    /// Left behind, `laneCount` still reports the old pairing and the compact
    /// progress bar sums totals for windows that are no longer paired at all —
    /// so leaving dual-site has to clear them, not merely stop using them.
    func clearDualLaneState() {
        laneSessionAIndices = []
        laneSessionBIndices = []
        laneStates = []
        laneCompletedCounts = []
        dualCredentialIDBySessionIndex = [:]
        dualNeedsBurn = [:]
        dualQuadActive = false
    }

    /// Changes the active grid and immediately recalculates any current
    /// dual-site assignment for the new row/column geometry.
    func setGridSize(_ newSize: WindowGridSize) {
        guard newSize != gridSize else { return }
        gridSize = newSize

        // Clear any disabled state from a previous dual-site 3×3 layout.
        for s in activeSessions { s.isDisabled = false }

        if isDualTargetMode,
           newSize.supportsDualSite,
           let urlA = dualSiteURLA,
           let urlB = dualSiteURLB {
            applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: dualSiteSplitPattern)
        } else if !newSize.supportsDualSite {
            isDualTargetMode = false
            for session in activeSessions { session.targetSiteIndex = 0 }
            clearDualLaneState()
        }
        refocusIfDisabled()
    }

    /// Moves focus off any disabled (unused) cell so the shared toolbar can
    /// never point at an inert window — e.g. the 3×3 center in dual-site
    /// mode after the user last tapped it.
    func refocusIfDisabled() {
        if focusedIndex >= activeCount || sessions[focusedIndex].isDisabled {
            focusedIndex = enabledSessions.first?.index ?? 0
        }
    }

    /// Read-only access to a dual-site lane's two sessions (URL A side, URL
    /// B side). Valid for `lane` in `0..<laneCount`.
    func lanePair(_ lane: Int) -> (QuadSession, QuadSession) {
        (sessionA(forLane: lane), sessionB(forLane: lane))
    }

    func navigateAll(to url: URL) {
        if isDualTargetMode { clearDualLaneState() }
        isDualTargetMode = false
        dualSiteURLA = url
        dualSiteURLB = nil
        for s in activeSessions {
            s.targetSiteIndex = 0
            s.isDisabled = false
            navigate(s, to: url)
        }
    }

    /// Navigates every currently assigned Site A or Site B browser tile.
    func navigateTargetSite(to url: URL, targetSiteIndex: Int) {
        guard targetSiteIndex == 0 || targetSiteIndex == 1 else { return }
        if targetSiteIndex == 0 { dualSiteURLA = url } else { dualSiteURLB = url }
        for session in activeSessions where session.targetSiteIndex == targetSiteIndex && !session.isDisabled {
            navigate(session, to: url)
        }
    }

    /// Recalculates an exactly even A/B assignment for the active grid, then
    /// navigates only tiles whose target changed. The 3×3 layout marks its
    /// center window as disabled and splits the remaining 8 evenly.
    func applyDualSiteTargets(urlA: URL, urlB: URL, pattern: DualSiteSplitPattern) {
        guard gridSize.supportsDualSite else {
            navigateAll(to: urlA)
            return
        }

        // A pattern that cannot halve this grid evenly would cut a row or a
        // column down the middle while still calling itself "Left / Right".
        // Checkerboard always divides cleanly, so it is the honest fallback.
        let effectivePattern = pattern.splitsCleanly(in: gridSize) ? pattern : .checkerboard

        isDualTargetMode = true
        dualSiteURLA = urlA
        dualSiteURLB = urlB
        dualSiteSplitPattern = effectivePattern

        for session in activeSessions {
            let target = effectivePattern.targetSiteIndex(for: session.index, in: gridSize)
            if target == -1 {
                // 3×3 center window — disabled in dual-site mode.
                session.isDisabled = true
                session.targetSiteIndex = 0
                session.webView?.stopLoading()
                continue
            }
            session.isDisabled = false
            session.targetSiteIndex = target
            navigate(session, to: target == 0 ? urlA : urlB)
        }
        rebuildLaneMapping()
        refocusIfDisabled()
    }

    func representativeSession(forTargetSite targetSiteIndex: Int) -> QuadSession? {
        activeSessions.first { $0.targetSiteIndex == targetSiteIndex && !$0.isDisabled }
    }

    // MARK: - Page-load autofill & save-offer (multi-window)

    /// Fills a matching vault credential into one multi-window cell when
    /// Settings → Auto-fill on Page Load is enabled. Mirrors the
    /// single-window flow, keyed to this session's own domain.
    func handleQuadPageLoadAutofill(for session: QuadSession) {
        guard !anyRCRRunning, !session.rcrRunning else { return }
        guard browserViewModel?.isRCRRunning != true else { return }
        // While following the leader, its typing is mirrored into every
        // follower — independent per-window autofill would fight that.
        guard !isFollowLeaderEnabled else { return }
        let autoFillEnabled = UserDefaults.standard.object(forKey: SettingsKey.autoFillOnPageLoad) as? Bool ?? true
        guard autoFillEnabled else { return }

        let domain = session.domain
        guard !domain.isEmpty, browserViewModel?.isDomainExcluded(domain) == false else { return }
        guard let webView = session.webView else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Brief settle so SPA login forms finish mounting.
            try? await Task.sleep(for: .milliseconds(350))
            guard !self.anyRCRRunning, !session.rcrRunning else { return }

            let detectRaw = try? await webView.evaluateJavaScript(
                JavaScriptInjectionService.detectLoginFormScript()
            )
            let hasLoginForm: Bool = {
                if let json = detectRaw as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let flag = dict["hasLoginForm"] as? Bool {
                    return flag
                }
                return false
            }()
            guard hasLoginForm else { return }

            guard let context = self.modelContext else { return }
            let domainLower = domain.lowercased()
            let domainVariants = BrowserViewModel.autofillDomainCandidates(for: domainLower)
            let descriptor = FetchDescriptor<Credential>(
                sortBy: [
                    SortDescriptor(\.lastUsedAt, order: .reverse),
                    SortDescriptor(\.usageCount, order: .reverse),
                    SortDescriptor(\.updatedAt, order: .reverse)
                ]
            )
            let all = (try? context.fetch(descriptor)) ?? []
            guard let match = all.first(where: { domainVariants.contains($0.domain.lowercased()) }) else {
                return
            }
            guard let password = KeychainService.shared.getPassword(for: match.id), !password.isEmpty else {
                return
            }

            let siteSetting = self.browserViewModel?.fetchSiteSetting(for: domainLower)
            let fillScript = JavaScriptInjectionService.fillCredentialScript(
                username: match.username,
                password: password,
                usernameSelector: siteSetting?.usernameSelector,
                passwordSelector: siteSetting?.passwordSelector,
                suppressKeyboard: true
            )
            let fillRaw = try? await webView.evaluateJavaScript(fillScript)
            let filledCount: Int = {
                if let json = fillRaw as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let count = dict["filled"] as? Int {
                    return count
                }
                return 0
            }()
            guard filledCount > 0 else { return }

            match.lastUsedAt = Date()
            match.usageCount += 1
            try? context.save()

            if let siteSetting, siteSetting.isAutoLoginEnabled {
                let submit = JavaScriptInjectionService.submitFormScript(
                    submitSelector: siteSetting.submitButtonSelector
                )
                _ = try? await webView.evaluateJavaScript(submit)
            } else {
                self.browserViewModel?.showToast("Filled login for \(match.username)")
            }
        }
    }

    /// Offers to save a manually submitted login from a multi-window cell.
    func detectAndOfferSaveQuad(session: QuadSession) {
        let offerEnabled = UserDefaults.standard.object(forKey: SettingsKey.offerToSavePasswords) as? Bool ?? true
        guard offerEnabled else { return }
        let domain = session.domain
        guard !domain.isEmpty, browserViewModel?.isDomainExcluded(domain) == false else { return }

        let script = JavaScriptInjectionService.extractFilledCredentialsScript()
        session.webView?.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let found = dict["found"] as? Bool, found,
                      let username = dict["username"] as? String, !username.isEmpty,
                      let password = dict["password"] as? String, !password.isEmpty else { return }

                guard let context = self.modelContext else { return }
                let domainLower = domain.lowercased()
                let descriptor = FetchDescriptor<Credential>(
                    predicate: #Predicate<Credential> {
                        $0.username == username && $0.domain == domainLower
                    }
                )
                let alreadyExists = (try? context.fetch(descriptor).first) != nil
                if !alreadyExists {
                    self.browserViewModel?.detectedUsername = username
                    self.browserViewModel?.detectedPassword = password
                    self.browserViewModel?.detectedDomain = domainLower
                    self.browserViewModel?.isShowingSaveCredentialAlert = true
                }
            }
        }
    }

    private func navigate(_ session: QuadSession, to url: URL) {
        session.url = url
        // Holding for a cloned session: record where this window is going
        // but don't load yet — the clone issues the load once the donated
        // cookies are in place, so the page never renders signed out.
        guard !session.isRestoringSession else { return }
        guard session.webView?.url != url else { return }
        session.webView?.load(URLRequest(url: url))
    }

    // MARK: - Queue snapshot for the per-session pill

    func queueSnapshot(for s: QuadSession, upcomingLimit: Int = 8) -> [RCRQueueItem] {
        guard !s.rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        let total = s.rcrQueueIDs.count
        let upper = min(s.rcrIndex + upcomingLimit + 1, total)
        for i in s.rcrIndex..<upper {
            let id = s.rcrQueueIDs[i]
            let username = i < s.rcrQueueUsernames.count ? s.rcrQueueUsernames[i] : ""
            let pwCount = i < s.rcrQueuePasswordCounts.count ? s.rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount
            ))
        }
        return items
    }

    func completedSnapshot(for s: QuadSession) -> [RCRQueueItem] {
        guard !s.rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        for (i, id) in s.rcrQueueIDs.enumerated() where s.rcrCompletedIDs.contains(id) {
            let username = i < s.rcrQueueUsernames.count ? s.rcrQueueUsernames[i] : ""
            let pwCount = i < s.rcrQueuePasswordCounts.count ? s.rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount
            ))
        }
        return items
    }

    // MARK: - Quad RCR (normal 4-way split — unchanged)

    func startQuadRCR(targetURL: URL) {
        guard !anyRCRRunning, !isStartingRCR else { return }
        guard let context = modelContext else { return }
        autoDisableFollowLeader(reason: "Follow the Leader off — run started")
        dualQuadActive = false
        FillHealerEngine.shared.resetRunBudget()
        ParkedSessionStore.shared.markRunStarted()
        NeedsReviewStore.shared.markRunStarted()
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }
        let excluded = browserViewModel?.excludedDomainSet ?? []
        let queue = all.filter { !excluded.contains(ExcludedDomain.canonicalize($0.domain)) }
        guard !queue.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }
        // Reset all active sessions and clear any leftover disabled state.
        for s in activeSessions {
            s.isDisabled = false
        }

        // Keychain reads block the caller — fetch password counts off the
        // main thread so a large vault can't freeze the UI at run start.
        isStartingRCR = true
        rcrStartGeneration &+= 1
        let startGeneration = rcrStartGeneration
        let credIDs = queue.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            let counts = await Task.detached {
                credIDs.map { KeychainService.shared.getPasswords(for: $0).count }
            }.value
            // A stop (or a stale earlier start) during the preflight aborts
            // this run before it touches anything.
            guard self.isStartingRCR, self.rcrStartGeneration == startGeneration else { return }
            self.isStartingRCR = false
            self.partitionAndStart(queue: queue, targetURL: targetURL, passwordCounts: counts)
        }
    }

    /// Splits the vault evenly across every active window (4/6/8/9/12/16) using
    /// balanced round-robin so that every window gets either floor(N/W) or
    /// ceil(N/W) credentials — guaranteed equal to within one, no matter
    /// how small the vault. For repeatability across runs the queue is
    /// sorted the same way every time (domain → username). Disabled windows
    /// (e.g. 3×3 center in dual-site mode) are excluded from the partition.
    private func partitionAndStart(queue: [Credential], targetURL: URL, passwordCounts: [Int]) {
        guard let context = modelContext else { return }

        let participants = enabledSessions
        let count = participants.count
        guard count > 0 else {
            browserViewModel?.showToast("No active windows", force: true)
            return
        }
        let slices = Self.roundRobinSlices(queue, windowCount: count)

        let domain = targetURL.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared
        let countsByID = Dictionary(uniqueKeysWithValues: zip(queue.map(\.id), passwordCounts))

        for (sliceIdx, s) in participants.enumerated() {
            let creds = slices[sliceIdx]
            if !creds.isEmpty {
                let allFinished = creds.allSatisfy { c in
                    tracker.credentialIsFinished(
                        context: context,
                        credentialID: c.id,
                        targetDomain: domain,
                        totalPasswords: countsByID[c.id] ?? 0
                    )
                }
                if allFinished {
                    tracker.clearAttempts(context: context, credentialIDs: Set(creds.map(\.id)), targetDomain: domain)
                }
            }
            startSessionRCR(s, creds: creds, targetURL: targetURL, targetDomain: domain, countsByID: countsByID, context: context, tracker: tracker)
        }
    }

    private func startSessionRCR(
        _ s: QuadSession,
        creds: [Credential],
        targetURL: URL,
        targetDomain: String,
        countsByID: [String: Int],
        context: ModelContext,
        tracker: AttemptTrackingService
    ) {
        let credIDs = creds.map(\.id)
        let usernames = creds.map(\.username)
        let counts: [Int] = credIDs.map { countsByID[$0] ?? 0 }

        s.rcrQueueIDs = credIDs
        s.rcrQueueUsernames = usernames
        s.rcrQueuePasswordCounts = counts
        s.rcrTotal = credIDs.count
        s.rcrIndex = 0
        s.rcrPasswordIndex = 0
        s.rcrSuccessCount = 0
        s.rcrCompletedIDs = []
        s.rcrTargetURL = targetURL
        s.rcrCurrentDomain = targetDomain
        s.rcrAwaitingNavigation = false
        s.needsPostBurnSettle = false

        while s.rcrIndex < s.rcrTotal {
            let id = s.rcrQueueIDs[s.rcrIndex]
            let total = s.rcrQueuePasswordCounts[s.rcrIndex]
            let finished = tracker.credentialIsFinished(
                context: context,
                credentialID: id,
                targetDomain: targetDomain,
                totalPasswords: total
            )
            if finished || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                s.rcrCompletedIDs.insert(id)
                s.rcrIndex += 1
            } else {
                break
            }
        }

        if s.rcrTotal > 0 && s.rcrIndex < s.rcrTotal {
            s.rcrRunning = true
            s.rcrStatus = .navigating
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrScrollEnableScript(),
                completionHandler: nil
            )
            Task { await self.runCurrent(session: s) }
        } else {
            s.rcrRunning = false
            s.rcrStatus = .finished
        }
    }

    func stopQuadRCR(reason: String? = nil) {
        // Invalidate any in-flight start preflight.
        isStartingRCR = false
        rcrStartGeneration &+= 1
        // Wake every suspended runner so nothing hangs on a continuation.
        isQuadRCRPaused = false
        for continuation in quadPauseContinuations { continuation.resume() }
        quadPauseContinuations = []
        for (index, continuation) in freezeContinuations {
            continuation.resume()
            sessions[index].isRCRFrozen = false
        }
        freezeContinuations = [:]
        for s in enabledSessions where s.rcrRunning {
            s.rcrRunning = false
            s.rcrStatus = .idle
            s.rcrAwaitingNavigation = false
            s.rcrExtraSubmitsInFlight = false
            s.rcrJudging = false
            s.needsPostBurnSettle = false
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrUninstallObserverScript(),
                completionHandler: nil
            )
        }
        for s in activeSessions {
            s.rcrWatchdog?.cancel()
            s.rcrWatchdog = nil
            // Don't leave plaintext passwords sitting in memory after a stop.
            s.rcrPasswords = []
            s.rcrPasswordsCredentialID = ""
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrScrollDisableScript(),
                completionHandler: nil
            )
        }
        dualQuadActive = false
        laneStates = []
        laneCompletedCounts = Array(repeating: 0, count: laneCount)
        dualNeedsBurn = [:]
        if let reason { browserViewModel?.showToast(reason) }
        ParkedSessionStore.shared.markRunFinished()
        browserViewModel?.offerNeedsReviewSummaryIfNeeded()
    }

    private func currentCredential(_ session: QuadSession) -> Credential? {
        guard session.rcrIndex < session.rcrQueueIDs.count, let context = modelContext else { return nil }
        let id = session.rcrQueueIDs[session.rcrIndex]
        let descriptor = FetchDescriptor<Credential>(predicate: #Predicate<Credential> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: - Grid cockpit (pause-all / freeze / skip / retry / speed)

    /// The live speed profile — shared with single-window mode through the
    /// host browser so the dial stays consistent across modes.
    var activeSpeedProfile: SpeedProfile {
        browserViewModel?.runSpeedProfile ?? SpeedProfile.saved
    }

    /// Pauses or resumes every running window between attempts. The
    /// in-flight attempt always completes.
    func setQuadRCRPaused(_ paused: Bool) {
        guard anyRCRRunning, paused != isQuadRCRPaused else { return }
        isQuadRCRPaused = paused
        if paused {
            for s in activeSessions { cancelRCRWatchdog(for: s) }
            browserViewModel?.showToast("All windows paused")
        } else {
            for continuation in quadPauseContinuations { continuation.resume() }
            quadPauseContinuations = []
            for s in activeSessions where s.rcrRunning
                && (s.rcrStatus == .waiting || s.rcrStatus == .navigating) {
                armRCRWatchdog(for: s)
            }
            browserViewModel?.showToast("Run resumed")
        }
    }

    func toggleQuadRCRPause() {
        setQuadRCRPaused(!isQuadRCRPaused)
    }

    /// Freezes or thaws one window. Frozen windows rest between attempts
    /// while the rest of the grid keeps working.
    func setSessionFrozen(_ s: QuadSession, _ frozen: Bool) {
        guard frozen != s.isRCRFrozen else { return }
        s.isRCRFrozen = frozen
        if frozen {
            cancelRCRWatchdog(for: s)
            browserViewModel?.showToast("\(s.id) frozen — rests between attempts")
        } else {
            freezeContinuations[s.index]?.resume()
            freezeContinuations[s.index] = nil
            if s.rcrRunning, s.rcrStatus == .waiting || s.rcrStatus == .navigating {
                armRCRWatchdog(for: s)
            }
            browserViewModel?.showToast("\(s.id) thawed")
        }
    }

    func toggleSessionFrozen(_ s: QuadSession) {
        setSessionFrozen(s, !s.isRCRFrozen)
    }

    /// Suspends a session's runner while pause-all is on or the window is
    /// frozen. Every async leg of a session's run passes through here.
    func waitIfPausedOrFrozen(_ s: QuadSession) async {
        if isQuadRCRPaused {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                quadPauseContinuations.append(continuation)
            }
        }
        if s.isRCRFrozen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                freezeContinuations[s.index] = continuation
            }
        }
    }

    /// Skips the current credential in one window: records it as skipped
    /// with a reason and moves that window's run on. In dual-site mode the
    /// skip finishes this window's side of the lane so the pairing stays
    /// in sync.
    func skipCurrentForSession(_ s: QuadSession) {
        guard s.rcrRunning, s.rcrIndex < s.rcrQueueIDs.count else { return }
        cancelRCRWatchdog(for: s)
        s.rcrJudging = false
        s.rcrExtraSubmitsInFlight = false
        s.rcrAttemptGeneration &+= 1
        if dualQuadActive {
            let lane = laneIndex(for: s)
            guard let credential = currentDualCredential(s) else { return }
            if let context = modelContext {
                let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
                _ = AttemptTrackingService.shared.recordAttempt(
                    context: context,
                    credentialID: credential.id,
                    username: credential.username,
                    password: password,
                    passwordIndex: s.rcrPasswordIndex + 1,
                    passwordTotal: s.rcrPasswords.count,
                    targetDomain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
                    sessionTag: s.sessionTag,
                    status: .skipped,
                    judge: SuccessJudgeEngine.Decision.local(
                        status: .skipped,
                        verdict: "skipped",
                        confidence: 1,
                        reason: "Skipped by you during the run"
                    )
                )
            }
            browserViewModel?.showToast("Skipped \(credential.username) (\(s.id))")
            finishDualSide(session: s, lane: lane, status: .skipped)
            return
        }
        guard let credential = currentCredential(s) else { return }
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
                sessionTag: s.sessionTag,
                status: .skipped,
                judge: SuccessJudgeEngine.Decision.local(
                    status: .skipped,
                    verdict: "skipped",
                    confidence: 1,
                    reason: "Skipped by you during the run"
                )
            )
        }
        browserViewModel?.showToast("Skipped \(credential.username) (\(s.id))")
        s.rcrCompletedIDs.insert(credential.id)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        s.rcrPasswords = []
        s.rcrPasswordsCredentialID = ""
        Task { await runCurrent(session: s) }
    }

    /// Re-fills and re-submits the password a window just tried.
    func retryCurrentForSession(_ s: QuadSession) {
        guard s.rcrRunning, !s.rcrPasswords.isEmpty,
              s.rcrPasswordIndex < s.rcrPasswords.count else { return }
        guard !s.rcrJudging else {
            browserViewModel?.showToast("Judging the current attempt — retry in a moment", force: true)
            return
        }
        guard s.rcrStatus == .waiting || s.rcrStatus == .submitting else {
            browserViewModel?.showToast("Retry is available while watching a submit", force: true)
            return
        }
        cancelRCRWatchdog(for: s)
        s.rcrJudging = false
        s.rcrExtraSubmitsInFlight = false
        s.rcrAttemptGeneration &+= 1
        browserViewModel?.showToast("Retrying \(s.rcrCurrentUsername) (\(s.id))")
        if dualQuadActive {
            Task { await attemptFillDual(session: s, lane: laneIndex(for: s)) }
        } else {
            Task { await attemptFill(session: s) }
        }
    }

    // MARK: - Follow the Leader

    /// True when the mode can be offered: a single-site grid with 2+ live
    /// windows (never in dual-site split, never in single-window view).
    ///
    /// This is the single source of truth for "can this layout follow a
    /// leader". The menu that offers the mode asks here rather than deciding
    /// for itself from the view model's own dual-site flag — those two can
    /// disagree after a same-size re-pick, which is how the menu ended up
    /// offering a mode that then refused to start.
    var canOfferFollowLeader: Bool {
        !isDualTargetMode && enabledSessions.count > 1
    }

    /// True while the leader is being copied exactly rather than best-effort.
    var isStrictFollowLeader: Bool {
        isFollowLeaderEnabled && followLeaderMode.isStrict
    }

    /// True while an irreversible leader action is being held back until the
    /// followers catch up.
    var isFollowLeaderGateHolding: Bool { followLeaderGateWaiting > 0 }

    /// The windows currently being kept in step: every live window except the
    /// leader, minus any that have been dropped out of the squad.
    var followLeaderSquad: [QuadSession] {
        guard let leader = leaderSession else { return [] }
        return enabledSessions.filter { $0.index != leader.index && !$0.flDropped }
    }

    /// Switches between Relaxed and Unbreakable.
    ///
    /// Refused while windows are still catching up: flipping mid-flow would
    /// copy the first half of a form one way and the second half the other,
    /// which is the one outcome neither mode is allowed to produce.
    func setFollowLeaderMode(_ mode: FollowLeaderSyncMode) {
        guard mode != followLeaderMode else { return }
        if isFollowLeaderEnabled {
            let busy = followLeaderSquad.filter { isFollowLeaderBusy($0) }
            guard busy.isEmpty else {
                Self.followLeaderLog.info("mode change blocked — \(busy.count) window(s) still catching up")
                browserViewModel?.showToast("Let the windows catch up first", force: true)
                return
            }
        }
        followLeaderMode = mode
        mode.save()
        Self.followLeaderLog.info("sync mode → \(mode.rawValue, privacy: .public)")
        guard isFollowLeaderEnabled else { return }
        // Queues carry their own strictness, so they are rebuilt rather than
        // reused. They are known to be empty — that is what was just checked.
        followLeaderQueues = [:]
        followLeaderPageJournal = []
        followLeaderLedger.removeAll()
        releaseFollowLeaderGate()
        for s in sessions {
            s.flRepairing = false
            s.flRepairCount = 0
            s.flRepairSeq = -1
            s.flDropped = false
            s.flPending = 0
        }
        armFollowLeaderRecorder(on: leaderSession)
        browserViewModel?.showToast("Follow the Leader — \(mode.label)")
    }

    /// The Leader is the first live window. Nil unless the mode is on.
    var followLeaderIndex: Int? {
        isFollowLeaderEnabled ? enabledSessions.first?.index : nil
    }

    private var leaderSession: QuadSession? { enabledSessions.first }

    func toggleFollowLeader() { setFollowLeaderEnabled(!isFollowLeaderEnabled) }

    func setFollowLeaderEnabled(_ on: Bool) {
        guard on != isFollowLeaderEnabled else { return }
        if on {
            guard !anyRCRRunning else {
                Self.followLeaderLog.info("enable blocked — run active")
                browserViewModel?.showToast("Stop the run before Follow the Leader", force: true)
                return
            }
            guard canOfferFollowLeader else {
                Self.followLeaderLog.info("enable blocked — dual=\(self.isDualTargetMode), live windows=\(self.enabledSessions.count)")
                if isDualTargetMode {
                    browserViewModel?.showToast("Leave Dual Site before Follow the Leader", force: true)
                } else {
                    browserViewModel?.showToast("Follow the Leader needs at least 2 windows", force: true)
                }
                return
            }
            isFollowLeaderEnabled = true
            focusedIndex = leaderSession?.index ?? 0
            followLeaderQueues = [:]
            followLeaderResyncAt = [:]
            followLeaderPageJournal = []
            followLeaderLedger.removeAll()
            followLeaderGateWaiting = 0
            // Fresh misfire/replay tallies for this session of the mode.
            for s in sessions {
                s.flWorking = false
                s.flReplayCount = 0
                s.flMisfireCount = 0
                s.flCleanStreak = 0
                s.flPending = 0
                s.flAwaitingLoad = false
                s.flResyncCount = 0
                s.flSyncPulse = 0
                s.flCrashCount = 0
                s.flRecovering = false
                s.flRepairing = false
                s.flRepairCount = 0
                s.flRepairSeq = -1
                s.flDropped = false
            }
            // Keep the device (and every hidden follower) awake so the
            // mirrored automation never gets suspended mid-flow.
            UIApplication.shared.isIdleTimerDisabled = true
            // Followers must already be signed in before the leader's typing
            // starts arriving, so push its session out first.
            browserViewModel?.cloneLeaderSessionToFollowers()
            installFollowLeaderRecorder()
            Self.followLeaderLog.info("enabled — leader=\(self.leaderSession?.id ?? "S1", privacy: .public) style=\(self.followLeaderDisplayStyle.rawValue, privacy: .public) mode=\(self.followLeaderMode.rawValue, privacy: .public)")
            let modeNote = followLeaderMode.isStrict ? " — unbreakable" : ""
            browserViewModel?.showToast("Follow the Leader on — \(leaderSession?.id ?? "S1") leads\(modeNote)")
        } else {
            disableFollowLeader(silent: false, reason: "Follow the Leader off")
        }
    }

    /// Turns the mode off if it is on. Used when the layout no longer matches
    /// (grid resized, switched to dual-site or single, or a run started).
    func autoDisableFollowLeader(reason: String) {
        guard isFollowLeaderEnabled else { return }
        disableFollowLeader(silent: false, reason: reason)
    }

    private func disableFollowLeader(silent: Bool, reason: String?) {
        guard isFollowLeaderEnabled else { return }
        Self.followLeaderLog.info("disabled — \(reason ?? "no reason given", privacy: .public)")
        isFollowLeaderEnabled = false
        clearFollowLeaderWork()
        UIApplication.shared.isIdleTimerDisabled = false
        leaderSession?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.followLeaderDisableScript(),
            completionHandler: nil
        )
        if let reason, !silent { browserViewModel?.showToast(reason) }
    }

    /// Drops every pending mirrored action and stops all in-flight replay
    /// work, so turning the mode off (or resizing the grid, or starting a
    /// run) leaves nothing queued behind it.
    private func clearFollowLeaderWork() {
        followLeaderGeneration &+= 1
        for task in followLeaderTasks { task.cancel() }
        followLeaderTasks = []
        for task in followLeaderPumps.values { task.cancel() }
        followLeaderPumps = [:]
        followLeaderQueues = [:]
        followLeaderResyncAt = [:]
        followLeaderPageJournal = []
        followLeaderLedger.removeAll()
        followLeaderGateTask?.cancel()
        followLeaderGateTask = nil
        followLeaderGateWaiting = 0
        for s in sessions {
            s.flWorking = false
            s.flPending = 0
            s.flAwaitingLoad = false
            s.flRecovering = false
            s.flRepairing = false
            s.flDropped = false
        }
    }

    private func installFollowLeaderRecorder() {
        armFollowLeaderRecorder(on: leaderSession)
    }

    /// Arms the recorder in the Leader window and flushes anything it
    /// buffered before arming, so actions taken while a page was still
    /// coming up are mirrored rather than dropped. The current mode goes with
    /// it: the recorder's fidelity is decided in the page, not here.
    private func armFollowLeaderRecorder(on session: QuadSession?) {
        session?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.followLeaderArmScript(strict: followLeaderMode.isStrict),
            completionHandler: nil
        )
    }

    /// Arms as soon as the Leader's new document exists — well before the
    /// page has finished loading.
    func followLeaderCellDidCommit(session s: QuadSession) {
        guard isFollowLeaderEnabled, s.index == leaderSession?.index else { return }
        // A new document is a new page, and the repair journal only ever
        // describes the page on screen. The repair allowance resets with it:
        // a window that struggled on the sign-in page should not be dropped
        // for that three pages later.
        let isNewPage = !FollowLeaderSync.isSamePage(leaderPageKey, s.url)
        leaderPageKey = FollowLeaderSync.normalizedKey(s.url)
        followLeaderPageJournal = []
        for follower in sessions {
            follower.flRepairCount = 0
            follower.flRepairSeq = -1
            // The drift allowance is budgeted per page for the same reason
            // the repair allowance is. Spent on one page, a window was
            // previously left stranded for every page after it — so a genuine
            // new document refills it. A reload of the same page does not,
            // which is what keeps a redirect loop from resetting itself
            // forever.
            if isNewPage {
                follower.flResyncCount = 0
                followLeaderResyncAt[follower.index] = nil
            }
        }
        armFollowLeaderRecorder(on: s)
    }

    /// Re-arms once the Leader's page settles (covering sub-frames that only
    /// appeared late in the load), and re-checks an idle follower for drift.
    func followLeaderCellDidFinish(session s: QuadSession) {
        guard isFollowLeaderEnabled else { return }
        if s.index == leaderSession?.index {
            armFollowLeaderRecorder(on: s)
            return
        }
        if followLeaderQueues[s.index]?.isEmpty ?? true {
            resyncFollowerIfDrifted(s)
        }
    }

    /// Cascades a follower's head start the same way the replay queue does.
    /// Uncapped, a Slow eight-window grid left the last window idle for the
    /// best part of two seconds before it even started loading.
    private func navigationLead(position: Int, profile: SpeedProfile) -> TimeInterval {
        FollowLeaderPacing.leadIn(
            position: position + 1,
            step: profile.followLeaderStaggerStep.seconds,
            cap: profile.followLeaderMaxStagger.seconds
        )
    }

    /// Receives one recorded Leader action and queues it for every follower.
    /// Queueing is immediate for all of them — no window waits on the ones
    /// ahead of it.
    func handleFollowLeaderEvent(session s: QuadSession, payload: [String: Any]) {
        guard isFollowLeaderEnabled, let leader = leaderSession, s.index == leader.index else { return }
        // Not an action: the leader is asking permission to perform something
        // irreversible. Its own event is being held in the page until the
        // squad has caught up.
        if (payload["kind"] as? String) == "gate" {
            handleFollowLeaderGate()
            return
        }
        followLeaderSeq &+= 1
        guard let action = FollowLeaderAction(payload: payload, seq: followLeaderSeq) else { return }
        let squad = followLeaderSquad
        guard !squad.isEmpty else { return }
        if isStrictFollowLeader {
            appendToPageJournal(action)
            followLeaderLedger.record(
                seq: action.seq,
                kind: action.kind,
                summary: action.ledgerSummary,
                isCommit: FollowLeaderCommitPoint.isCommit(action),
                windows: squad.map(\.index)
            )
        }
        let strict = isStrictFollowLeader
        for follower in squad {
            var queue = followLeaderQueues[follower.index] ?? FollowLeaderQueue(isStrict: strict)
            // In rotate mode a card field is swapped for this window's own
            // card before it is queued, so every card value the window ever
            // replays comes from one card — never the leader's number with
            // this window's expiry.
            queue.enqueue(cardSubstitutedAction(action, for: follower))
            followLeaderQueues[follower.index] = queue
            follower.flPending = queue.count
            startFollowLeaderPump(for: follower)
        }
    }

    /// Records an action in the page journal a repair replays.
    ///
    /// One deliberate compaction: a run of consecutive scrolls collapses to
    /// its resting position. Rebuilding a page needs the state it ended in,
    /// not the path the viewport took to get there — and a keystroke-exact
    /// recorder produces a scroll every frame, which would make a repair
    /// slower than the flow it exists to rescue. The live queue still
    /// replays every one of them; this is only the rebuild recipe.
    private func appendToPageJournal(_ action: FollowLeaderAction) {
        if action.kind == .scroll,
           let last = followLeaderPageJournal.indices.last,
           followLeaderPageJournal[last].kind == .scroll {
            followLeaderPageJournal[last] = action
        } else {
            followLeaderPageJournal.append(action)
        }
        if followLeaderPageJournal.count > Self.followLeaderJournalCap {
            followLeaderPageJournal.removeFirst(followLeaderPageJournal.count - Self.followLeaderJournalCap)
        }
    }

    /// Starts the single serial drain task for one follower, if it isn't
    /// already running.
    private func startFollowLeaderPump(for follower: QuadSession) {
        guard isFollowLeaderEnabled, followLeaderPumps[follower.index] == nil else { return }
        let index = follower.index
        let generation = followLeaderGeneration
        let position = followLeaderPosition(of: follower)
        followLeaderPumps[index] = Task { @MainActor [weak self] in
            await self?.drainFollowLeaderQueue(index: index, generation: generation, position: position)
            guard let self else { return }
            // Only retire our own registry slot. A cancelled pump can finish
            // after the mode was turned off and back on, and clearing the
            // entry then would let a second pump start alongside the new one —
            // which is exactly the concurrent-replay bug this queue exists to
            // prevent.
            guard self.followLeaderGeneration == generation else { return }
            self.followLeaderPumps.removeValue(forKey: index)
            guard self.isFollowLeaderEnabled else { return }
            // Anything enqueued during the final await gets a fresh pump.
            if let queue = self.followLeaderQueues[index], !queue.isEmpty,
               let session = self.sessions.first(where: { $0.index == index }) {
                self.startFollowLeaderPump(for: session)
            }
        }
    }

    /// Applies this follower's backlog strictly in order, one action at a
    /// time, until it is caught up with the Leader.
    private func drainFollowLeaderQueue(index: Int, generation: Int, position: Int) async {
        // Small per-window lead-in so a site never sees sixteen byte-identical
        // hits in the same millisecond. Capped, zero on Turbo, and charged
        // ONCE at the head of a catch-up — never per action. Paying it on
        // every action made the last window of a Slow grid fall two seconds
        // further behind with each step it replayed.
        let leadProfile = activeSpeedProfile
        let lead = FollowLeaderPacing.leadIn(
            position: position,
            step: leadProfile.followLeaderStaggerStep.seconds,
            cap: leadProfile.followLeaderMaxStagger.seconds
        )
        if lead > 0 {
            try? await Task.sleep(for: .seconds(lead))
            guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else { return }
        }
        while !Task.isCancelled {
            guard isFollowLeaderEnabled, followLeaderGeneration == generation else { return }
            guard let follower = sessions.first(where: { $0.index == index }),
                  !follower.isDisabled,
                  !follower.flDropped else { return }
            guard var queue = followLeaderQueues[index] else { return }
            guard let next = queue.dequeue() else {
                followLeaderQueues[index] = queue
                markFollowLeaderCaughtUp(follower)
                return
            }
            followLeaderQueues[index] = queue
            follower.flPending = queue.count
            // Read the dial per action rather than once per catch-up. A pump
            // started on Slow used to keep Slow's timings for its whole
            // backlog, so moving the dial to Turbo mid-flow appeared to do
            // nothing until every window happened to go idle.
            let profile = activeSpeedProfile
            guard let settlement = await applyMirroredAction(
                next,
                to: follower,
                generation: generation,
                profile: profile
            ) else { return }
            // Relaxed counts the miss and carries on — that is what makes it
            // relaxed. Unbreakable is not allowed to skip anything, so a miss
            // escalates into a repair, and only a failed repair drops the
            // window out of the squad.
            guard settlement == .missed, isStrictFollowLeader else { continue }
            let repaired = await repairFollower(
                follower,
                failedAction: next,
                generation: generation,
                profile: profile
            )
            guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else { return }
            guard repaired else { return }
        }
    }

    /// Rebuilds a window that could not copy an action: reload the leader's
    /// page, wait for it to become usable, then replay everything recorded on
    /// that page from the start so the window rejoins from a known state.
    ///
    /// Returns false when the repair itself failed, in which case the window
    /// has already been dropped from the squad.
    private func repairFollower(
        _ follower: QuadSession,
        failedAction: FollowLeaderAction,
        generation: Int,
        profile: SpeedProfile
    ) async -> Bool {
        // The same action missing again *after* a full page replay means the
        // replay is not the problem. This is what makes the ladder terminate
        // rather than loop.
        if follower.flRepairSeq == failedAction.seq {
            dropFollowerFromSquad(
                follower,
                reason: "\(follower.id) dropped — couldn't copy “\(failedAction.ledgerSummary)”"
            )
            return false
        }
        guard follower.flRepairCount < Self.followLeaderMaxRepairs else {
            dropFollowerFromSquad(follower, reason: "\(follower.id) dropped — needed repairing too often")
            return false
        }
        guard let leader = leaderSession, let target = leader.url else {
            dropFollowerFromSquad(follower, reason: "\(follower.id) dropped — no page to replay")
            return false
        }

        follower.flRepairSeq = failedAction.seq
        follower.flRepairCount += 1
        follower.flRepairing = true
        followLeaderLedger.mark(seq: failedAction.seq, window: follower.index, state: .repaired)
        Self.followLeaderLog.info(
            "repairing \(follower.id, privacy: .public) — replaying the page (attempt \(follower.flRepairCount))"
        )

        follower.url = target
        follower.webView?.load(URLRequest(url: target))
        // The navigation has not been reported yet, so give it a moment before
        // reading `isLoading` — otherwise the wait below sees a page that has
        // not started and decides it is already done.
        try? await Task.sleep(for: .milliseconds(140))
        let deadline = ContinuousClock.now.advanced(by: profile.followLeaderRepairTimeout)
        while follower.isLoading || follower.flRecovering || follower.isRestoringSession {
            guard ContinuousClock.now < deadline else {
                follower.flRepairing = false
                dropFollowerFromSquad(follower, reason: "\(follower.id) dropped — its page never came back")
                return false
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else {
                follower.flRepairing = false
                return false
            }
        }
        // Payment frames and late panels mount after the document reports
        // done; starting the replay before they exist would fail every action
        // that targets them.
        try? await Task.sleep(for: profile.followLeaderRepairSettle)
        guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else {
            follower.flRepairing = false
            return false
        }

        // Rebuild the backlog in one synchronous step: the whole page from the
        // start, then whatever the user did while it was reloading. Splicing
        // by sequence number rather than clearing is what stops a repair from
        // swallowing those keystrokes.
        var queue = followLeaderQueues[follower.index] ?? FollowLeaderQueue(isStrict: true)
        let journal = followLeaderPageJournal.map { cardSubstitutedAction($0, for: follower) }
        queue.replaceWithRepair(journal: journal)
        followLeaderQueues[follower.index] = queue
        follower.flPending = queue.count
        follower.flRepairing = false
        Self.followLeaderLog.info(
            "repaired \(follower.id, privacy: .public) — replaying \(journal.count) action(s)"
        )
        return true
    }

    /// Takes a window out of the squad for good.
    ///
    /// It keeps browsing where it is — nothing is closed and nothing is wiped
    /// — it simply stops receiving mirrored actions, which is what lets the
    /// windows that remain stay exactly in step instead of all waiting on the
    /// one that cannot comply.
    private func dropFollowerFromSquad(_ follower: QuadSession, reason: String) {
        guard !follower.flDropped else { return }
        follower.flDropped = true
        follower.flRepairing = false
        follower.flAwaitingLoad = false
        follower.flPending = 0
        followLeaderQueues[follower.index] = FollowLeaderQueue(isStrict: true)
        followLeaderLedger.markDropped(window: follower.index)
        Self.followLeaderLog.error("dropped \(follower.id, privacy: .public) — \(reason, privacy: .public)")
        browserViewModel?.showToast(reason, force: true)
        // Nothing left to keep in step: with one window the mode has no
        // meaning, so it stops rather than pretending to be on.
        if followLeaderSquad.isEmpty {
            disableFollowLeader(silent: false, reason: "Follow the Leader off — no windows left in sync")
        }
    }

    /// Runs one mirrored action inside a follower, retrying a couple of times
    /// before the window is flagged. Only hard failures retry — a click that
    /// simply produced no visible page change is never fired twice, which
    /// would risk a double submit.
    private func applyMirroredAction(
        _ action: FollowLeaderAction,
        to follower: QuadSession,
        generation: Int,
        profile: SpeedProfile
    ) async -> FollowLeaderSettlement? {
        follower.flWorking = true
        defer {
            follower.flWorking = false
            follower.flAwaitingLoad = false
        }

        var outcome = FollowLeaderApplyOutcome.failure(reason: "no-webview")
        for attempt in 0..<Self.followLeaderMaxAttempts {
            // Hold the action until the page is usable instead of firing it
            // into a half-built — or dead — document. Re-checked every
            // attempt because a web process can die mid-action, and retrying
            // into a corpse just burns the remaining attempts.
            if FollowLeaderReadiness.shouldHold(
                isLoading: follower.isLoading,
                isRestoringSession: follower.isRestoringSession,
                isRecovering: follower.flRecovering
            ) {
                follower.flAwaitingLoad = true
                await waitForFollowerReady(follower, generation: generation, profile: profile)
                follower.flAwaitingLoad = false
                guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else { return nil }
            }
            guard let webView = follower.webView else { break }
            outcome = await runMirroredAction(
                action,
                in: webView,
                timeout: profile.followLeaderActionTimeout.seconds
            )
            guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else { return nil }
            if outcome.ok { break }
            guard attempt < Self.followLeaderMaxAttempts - 1 else { break }
            try? await Task.sleep(for: profile.followLeaderRetryBackoff)
            guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else { return nil }
        }

        follower.flReplayCount += 1
        let settlement = FollowLeaderSettlement(outcome: outcome)
        recordSettlement(settlement, seq: action.seq, follower: follower)
        if settlement == .missed {
            Self.followLeaderLog.info(
                "miss \(follower.id, privacy: .public) kind=\(action.kind.rawValue, privacy: .public) reason=\(outcome.reason, privacy: .public)"
            )
            follower.flCleanStreak = 0
            // In Unbreakable a miss is not a misfire yet — it is about to be
            // repaired. Flagging the window here would brand one it went on
            // to fix. The repair and drop counters carry that story instead.
            if !isStrictFollowLeader { follower.flMisfireCount += 1 }
        } else {
            follower.flCleanStreak += 1
            // A badge that can never clear is a badge you learn to ignore.
            // Once the window has landed a clean run of actions, the earlier
            // miss is history rather than a live problem, so the flag goes.
            if follower.flCleanStreak >= Self.followLeaderCleanStreakToClear,
               follower.flMisfireCount > 0 {
                follower.flMisfireCount = 0
                Self.followLeaderLog.info("flag cleared — \(follower.id, privacy: .public) caught up clean")
            }
        }
        return settlement
    }

    /// Writes one window's result for one action into the ledger.
    ///
    /// A strict miss is deliberately left `pending`: the repair that follows
    /// marks the row `repaired`, or the drop marks it `dropped`. Recording it
    /// as missed first would make a row that was successfully rebuilt look
    /// like a permanent failure.
    private func recordSettlement(
        _ settlement: FollowLeaderSettlement,
        seq: Int,
        follower: QuadSession
    ) {
        guard isStrictFollowLeader else { return }
        switch settlement {
        case .confirmed:
            followLeaderLedger.mark(seq: seq, window: follower.index, state: .confirmed)
        case .delivered:
            followLeaderLedger.mark(seq: seq, window: follower.index, state: .delivered)
        case .missed:
            break
        }
    }

    /// Waits for a follower to finish loading, bounded by a safety watchdog
    /// so a dead page can never wedge that window's queue.
    private func waitForFollowerReady(
        _ follower: QuadSession,
        generation: Int,
        profile: SpeedProfile
    ) async {
        let deadline = ContinuousClock.now.advanced(
            by: SpeedProfile.effectiveWatchdog(.seconds(8), profile: profile)
        )
        while FollowLeaderReadiness.shouldHold(
            isLoading: follower.isLoading,
            isRestoringSession: follower.isRestoringSession,
            isRecovering: follower.flRecovering
        ) {
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard isFollowLeaderEnabled, followLeaderGeneration == generation, !Task.isCancelled else { return }
        }
    }

    /// Bridges the completion-handler form of `callAsyncJavaScript` with a
    /// hard timeout: a wedged web content process is abandoned instead of
    /// blocking every action queued behind it.
    private func runMirroredAction(
        _ action: FollowLeaderAction,
        in webView: WKWebView,
        timeout: TimeInterval
    ) async -> FollowLeaderApplyOutcome {
        // Wait for the answer directly rather than polling for it. The old
        // loop woke every 12ms for the whole life of every action; on a
        // sixteen-window grid that was well over a thousand pointless wakeups
        // a second across the squad, all of it spent asking a box whether it
        // had changed yet. The watchdog is now a single sleeping task, so a
        // wedged web process is still abandoned on time and an action that
        // completes normally costs exactly one resume.
        let box = FollowLeaderCallBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<FollowLeaderApplyOutcome, Never>) in
            let settle: @MainActor (FollowLeaderApplyOutcome) -> Void = { outcome in
                guard !box.isSettled else { return }
                box.isSettled = true
                box.watchdog?.cancel()
                box.watchdog = nil
                continuation.resume(returning: outcome)
            }

            box.watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                settle(.failure(reason: "timeout"))
            }

            webView.callAsyncJavaScript(
                JavaScriptInjectionService.followLeaderApplyBody(),
                arguments: ["action": action.jsArguments],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    settle(FollowLeaderApplyOutcome(jsResult: value))
                case .failure(let error):
                    settle(.failure(reason: "js-error-\((error as NSError).code)"))
                }
            }
        }
    }

    /// A window's web content process died — on a full grid of full-size
    /// pages that is usually the system reclaiming memory. Nothing used to
    /// notice: the tile stayed blank and every mirrored action after it spent
    /// three attempts and a full timeout before being counted as a miss.
    ///
    /// Reload it, hold its mirroring queue while the replacement process
    /// comes up, and let the chip say so.
    func webContentProcessDidTerminate(session s: QuadSession, webView: WKWebView) {
        Self.followLeaderLog.error("web process terminated — \(s.id, privacy: .public), reloading")
        s.isLoading = false
        s.estimatedProgress = 0
        s.flCrashCount &+= 1
        s.flRecovering = true
        if let target = webView.url ?? s.url {
            s.url = target
            webView.load(URLRequest(url: target))
        } else {
            webView.reload()
        }
        let index = s.index
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.followLeaderRecoveryHold)
            guard let self, !Task.isCancelled,
                  let session = self.sessions.first(where: { $0.index == index }),
                  session.flRecovering else { return }
            // The replacement never committed. Release the hold rather than
            // leaving this window's queue frozen behind a page that is not
            // coming back.
            session.flRecovering = false
            Self.followLeaderLog.error("recovery timed out — \(session.id, privacy: .public)")
        }
        followLeaderTasks.append(task)
        if followLeaderTasks.count > 240 {
            followLeaderTasks.removeAll { $0.isCancelled }
        }
    }

    /// Marks a follower fully caught up and pulses its chip.
    private func markFollowLeaderCaughtUp(_ follower: QuadSession) {
        follower.flPending = 0
        follower.flAwaitingLoad = false
        if follower.flReplayCount > 0 { follower.flSyncPulse &+= 1 }
        resyncFollowerIfDrifted(follower)
    }

    // MARK: - Follow the Leader — commit gates

    /// True while a window still owes the leader work — anything queued, in
    /// flight, loading, recovering or being repaired.
    ///
    /// Dropped windows are excluded on purpose: they are the one case where
    /// "never caught up" is the settled answer rather than a wait.
    private func isFollowLeaderBusy(_ s: QuadSession) -> Bool {
        if s.flDropped { return false }
        if s.flWorking || s.flRepairing || s.flAwaitingLoad || s.flRecovering { return true }
        if s.isLoading || s.isRestoringSession { return true }
        return !(followLeaderQueues[s.index]?.isEmpty ?? true)
    }

    /// The leader is about to do something irreversible and its own event is
    /// being held in the page. Wait until every window has confirmed
    /// everything before it, then let the leader's action through — so a
    /// submit or a payment only ever happens from an identical starting
    /// state across the grid.
    ///
    /// The wait is bounded. A window that never confirms must not be able to
    /// swallow a tap the user has already made, so the hold releases on a
    /// watchdog and says so.
    private func handleFollowLeaderGate() {
        guard isStrictFollowLeader else {
            releaseFollowLeaderGate()
            return
        }
        let waiting = followLeaderSquad.filter { isFollowLeaderBusy($0) }
        guard !waiting.isEmpty else {
            releaseFollowLeaderGate()
            return
        }
        followLeaderGateWaiting = waiting.count
        Self.followLeaderLog.info("commit held — waiting on \(waiting.count) window(s)")
        followLeaderGateTask?.cancel()
        let generation = followLeaderGeneration
        let profile = activeSpeedProfile
        followLeaderGateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: profile.followLeaderGateTimeout)
            while true {
                guard !Task.isCancelled,
                      self.isFollowLeaderEnabled,
                      self.followLeaderGeneration == generation else { return }
                let remaining = self.followLeaderSquad.filter { self.isFollowLeaderBusy($0) }
                self.followLeaderGateWaiting = remaining.count
                if remaining.isEmpty { break }
                guard ContinuousClock.now < deadline else {
                    Self.followLeaderLog.error("commit released on watchdog — \(remaining.count) window(s) never caught up")
                    let word = remaining.count == 1 ? "window" : "windows"
                    self.browserViewModel?.showToast(
                        "Went ahead — \(remaining.count) \(word) never caught up",
                        force: true
                    )
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self.releaseFollowLeaderGate()
        }
    }

    /// Lets a held commit through and clears the holding state.
    private func releaseFollowLeaderGate() {
        followLeaderGateTask?.cancel()
        followLeaderGateTask = nil
        if followLeaderGateWaiting > 0 {
            followLeaderGateWaiting = 0
            followLeaderGateReleases &+= 1
        }
        leaderSession?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.followLeaderReleaseGateScript(),
            completionHandler: nil
        )
    }

    /// Position of a follower in the mirroring order.
    ///
    /// Derived from `followLeaderSquad` — the same order the staggered
    /// navigation uses — so the two cannot disagree. Counting dropped windows
    /// here meant a grid that had lost a window spaced its remaining ones on
    /// slots nobody occupied, opening gaps that grew with the grid size.
    private func followLeaderPosition(of follower: QuadSession) -> Int {
        followLeaderSquad.firstIndex(where: { $0.index == follower.index }) ?? 0
    }

    /// Drops every queued mirrored action, in every window, before the grid
    /// deliberately moves somewhere else.
    ///
    /// A shared-URL navigation, a back, a forward or a reload replaces the
    /// page each of those queued actions was recorded against. Replaying them
    /// into the new document cannot succeed — the elements they name are gone
    /// — so every one becomes a miss, and in Unbreakable each miss then costs
    /// a full page-replay repair before the window gives up. Clearing first
    /// turns that storm into a clean start.
    ///
    /// Dropped windows stay dropped and crash recovery is left alone: neither
    /// is backlog, and both describe where a window actually is.
    private func clearFollowLeaderBacklog(reason: String) {
        guard isFollowLeaderEnabled else { return }
        // Bumping the generation is what stops an action already in flight
        // from landing on the new page after the queues are emptied.
        followLeaderGeneration &+= 1
        for task in followLeaderTasks { task.cancel() }
        followLeaderTasks = []
        for task in followLeaderPumps.values { task.cancel() }
        followLeaderPumps = [:]
        followLeaderQueues = [:]
        followLeaderPageJournal = []
        followLeaderResyncAt = [:]
        followLeaderGateTask?.cancel()
        followLeaderGateTask = nil
        followLeaderGateWaiting = 0
        for s in sessions {
            s.flWorking = false
            s.flPending = 0
            s.flAwaitingLoad = false
            s.flRepairing = false
            s.flRepairSeq = -1
        }
        Self.followLeaderLog.info("backlog cleared — \(reason, privacy: .public)")
    }

    /// Quietly pulls a follower back onto the Leader's page when it has
    /// drifted (a redirect, a popup, a tap that went somewhere else).
    ///
    /// Deliberately conservative: it only fires when both windows are idle
    /// and the follower's queue is empty, it waits out a settle window in
    /// case a redirect is still in flight, it ignores query strings (sites
    /// routinely append per-session tokens there), and it is rate-limited per
    /// window — so a legitimately different URL can never become a loop.
    private func resyncFollowerIfDrifted(_ follower: QuadSession) {
        guard isFollowLeaderEnabled, let leader = leaderSession, follower.index != leader.index else { return }
        // A dropped window is browsing on its own now. Dragging it back onto
        // the leader's page would be the one thing it was promised wouldn't
        // happen after it left the squad.
        guard !follower.flDropped else { return }
        guard !leader.isLoading, !follower.isLoading, !follower.isRestoringSession else { return }
        // A window the site keeps bouncing elsewhere (signed out, geo-gated)
        // is left alone after a few tries rather than reloaded forever.
        guard follower.flResyncCount < Self.followLeaderMaxResyncs else { return }
        guard let leaderURL = leader.url,
              FollowLeaderSync.needsResync(leader: leaderURL, follower: follower.url) else { return }
        let now = ContinuousClock.now
        if let last = followLeaderResyncAt[follower.index],
           now < last.advanced(by: .seconds(Self.followLeaderResyncCooldown)) { return }
        followLeaderResyncAt[follower.index] = now

        let index = follower.index
        let generation = followLeaderGeneration
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.followLeaderResyncSettle)
            guard let self, !Task.isCancelled,
                  self.isFollowLeaderEnabled,
                  self.followLeaderGeneration == generation else { return }
            guard let leader = self.leaderSession, !leader.isLoading, let target = leader.url else { return }
            guard let follower = self.sessions.first(where: { $0.index == index }),
                  !follower.isLoading,
                  !follower.isRestoringSession,
                  self.followLeaderQueues[index]?.isEmpty ?? true,
                  FollowLeaderSync.needsResync(leader: target, follower: follower.url) else { return }
            follower.flResyncCount += 1
            follower.url = target
            follower.webView?.load(URLRequest(url: target))
            Self.followLeaderLog.info("resync \(follower.id, privacy: .public) back onto the leader page")
        }
        followLeaderTasks.append(task)
        if followLeaderTasks.count > 240 {
            followLeaderTasks.removeAll { $0.isCancelled }
        }
    }

    /// Mirrors a shared-URL-bar navigation: the Leader goes now, followers
    /// fan out on the same cascading delay.
    func navigateFollowLeader(to url: URL) {
        guard isFollowLeaderEnabled, let leader = leaderSession else {
            navigateAll(to: url)
            return
        }
        clearFollowLeaderBacklog(reason: "navigated to a new page")
        navigate(leader, to: url)
        staggerToFollowers { follower in
            follower.url = url
            follower.webView?.load(URLRequest(url: url))
        }
    }

    func followLeaderGoBack() {
        clearFollowLeaderBacklog(reason: "went back")
        leaderSession?.webView?.goBack()
        staggerToFollowers { $0.webView?.goBack() }
    }

    func followLeaderGoForward() {
        clearFollowLeaderBacklog(reason: "went forward")
        leaderSession?.webView?.goForward()
        staggerToFollowers { $0.webView?.goForward() }
    }

    func followLeaderReload() {
        clearFollowLeaderBacklog(reason: "reloaded")
        leaderSession?.webView?.reload()
        staggerToFollowers { $0.webView?.reload() }
    }

    /// Schedules `action` on each follower window with a cascading delay
    /// (window 2 → 1s, window 3 → 2s, …), preserving action order via
    /// monotonic deadlines. Generation + cancellation guards stop any
    /// pending replay the moment the mode is turned off.
    private func staggerToFollowers(_ action: @escaping @MainActor (QuadSession) -> Void) {
        guard isFollowLeaderEnabled else { return }
        let followers = followLeaderSquad
        guard !followers.isEmpty else { return }
        let now = ContinuousClock.now
        let generation = followLeaderGeneration
        let profile = activeSpeedProfile
        for (position, follower) in followers.enumerated() {
            let deadline = now.advanced(by: .seconds(navigationLead(position: position, profile: profile)))
            let task = Task { [weak self, weak follower] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard let self, !Task.isCancelled,
                      self.isFollowLeaderEnabled,
                      self.followLeaderGeneration == generation,
                      let follower else { return }
                action(follower)
            }
            followLeaderTasks.append(task)
        }
        if followLeaderTasks.count > 240 {
            followLeaderTasks.removeAll { $0.isCancelled }
        }
    }

    private func runCurrent(session s: QuadSession) async {
        guard s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard s.rcrRunning else { return }
        // Skip credentials in temp-disabled cooldown OR ever perma-disabled.
        while s.rcrIndex < s.rcrQueueIDs.count {
            let id = s.rcrQueueIDs[s.rcrIndex]
            if TempDisabledStore.shared.isDisabled(credentialID: id)
                || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                s.rcrCompletedIDs.insert(id)
                s.rcrIndex += 1
                s.rcrPasswordIndex = 0
            } else {
                break
            }
        }
        guard s.rcrIndex < s.rcrQueueIDs.count else {
            s.rcrRunning = false
            s.rcrStatus = .finished
            cancelRCRWatchdog(for: s)
            // Don't leave plaintext passwords sitting in memory.
            s.rcrPasswords = []
            checkAllFinished()
            return
        }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            await runCurrent(session: s)
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value

        guard !allPasswords.isEmpty else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            await runCurrent(session: s)
            return
        }

        // Resume-safe filtering.
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        let filtered: [String]
        if let context = modelContext {
            if retryFailed {
                let tracker = AttemptTrackingService.shared
                filtered = allPasswords.filter { pw in
                    !tracker.isTerminallyAttempted(
                        context: context,
                        credentialID: credID,
                        passwordHash: PasswordFingerprint.hash(pw),
                        targetDomain: targetDomain
                    )
                }
            } else {
                let descriptor = FetchDescriptor<AttemptRecord>(
                    predicate: #Predicate<AttemptRecord> { rec in
                        rec.credentialID == credID
                            && rec.targetDomain == targetDomain
                            && rec.statusRaw != "pending"
                            && rec.statusRaw != "skipped"
                    }
                )
                let attempted = Set(((try? context.fetch(descriptor)) ?? []).map { $0.passwordHash })
                filtered = allPasswords.filter { !attempted.contains(PasswordFingerprint.hash($0)) }
            }
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            await runCurrent(session: s)
            return
        }

        s.rcrPasswords = filtered
        s.rcrPasswordIndex = 0
        s.rcrPasswordsCredentialID = credential.id
        s.rcrCurrentUsername = credential.username
        if let target = s.rcrTargetURL {
            s.rcrCurrentDomain = target.host(percentEncoded: false) ?? credential.domain
        }

        let liveURL = s.webView?.url ?? s.url
        if !BrowserViewModel.sameTarget(liveURL, s.rcrTargetURL), let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            // If this load never finishes (dead page, wedged process), the
            // watchdog advances the run instead of stalling forever.
            armRCRWatchdog(for: s)
            return
        }

        await attemptFill(session: s)
    }

    // MARK: - Per-attempt watchdog

    private static let rcrWatchdogTimeout: Duration = PageSettleService.attemptWatchdog

    /// Arms the per-attempt watchdog. If the page produces no state message
    /// within the timeout (navigation failure, dead page, wedged web
    /// process), the attempt is recorded as failed and the run advances —
    /// previously the session sat in "watching" forever. Stretched by the
    /// speed profile, never shrunk below base.
    func armRCRWatchdog(for s: QuadSession, timeout: Duration = rcrWatchdogTimeout) {
        let effective = SpeedProfile.effectiveWatchdog(timeout, profile: activeSpeedProfile)
        s.rcrWatchdog?.cancel()
        s.rcrWatchdog = Task { [weak self, weak s] in
            try? await Task.sleep(for: effective)
            guard let self, let s, !Task.isCancelled else { return }
            self.rcrWatchdogFired(session: s)
        }
    }

    func cancelRCRWatchdog(for s: QuadSession) {
        s.rcrWatchdog?.cancel()
        s.rcrWatchdog = nil
    }

    private func rcrWatchdogFired(session s: QuadSession) {
        guard s.rcrRunning, s.rcrStatus == .waiting || s.rcrStatus == .navigating else { return }
        // Paused or frozen windows must never be advanced by their own
        // watchdog — re-arm and wait.
        guard !isQuadRCRPaused, !s.isRCRFrozen else { armRCRWatchdog(for: s); return }
        s.rcrAwaitingNavigation = false

        if dualQuadActive {
            // Mirror the normal failed-password flow so lanes stay paired.
            let lane = laneIndex(for: s)
            guard let credential = currentDualCredential(s) else {
                finishDualSide(session: s, lane: lane, status: .failed)
                return
            }
            let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
            return
        }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            Task { await self.runCurrent(session: s) }
            return
        }
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        captureAndRecord(session: s, credential: credential, password: password, status: .failed)
        browserViewModel?.showToast("No response — skipping \(credential.username)")
        if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
            s.rcrPasswordIndex += 1
            Task { await self.attemptFill(session: s) }
        } else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
        }
    }

    private func attemptFill(session s: QuadSession) async {
        guard s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard s.rcrRunning else { return }
        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            await runCurrent(session: s)
            return
        }
        // Cross-credential guard: the in-memory password list must belong
        // to THIS credential. After a park or burn the list still holds the
        // previous credential's passwords — rebuild instead of filling the
        // wrong account's secrets.
        guard s.rcrPasswordsCredentialID == credential.id, !s.rcrPasswords.isEmpty else {
            s.rcrPasswords = []
            await runCurrent(session: s)
            return
        }
        let password = s.rcrPasswords[s.rcrPasswordIndex]
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = browserViewModel?.fetchSiteSetting(for: targetDomain)

        s.rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        let fillResult = try? await s.webView?.evaluateJavaScript(fillScript)

        var healedSubmitSelector: String? = nil
        if FillHealerEngine.fillMissed(fillResult),
           let webView = s.webView,
           let context = self.modelContext {
            let outcome = await FillHealerEngine.shared.healAndRefill(
                webView: webView,
                domain: targetDomain,
                sessionTag: s.sessionTag,
                username: credential.username,
                password: password,
                modelContext: context
            )
            healedSubmitSelector = outcome?.submitSelector
        }

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: healedSubmitSelector ?? siteSetting?.submitButtonSelector
        )
        guard let webViewForSubmit = s.webView else {
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            browserViewModel?.showToast("Window closed mid-submit — skipping \(credential.username)")
            advanceAfterFailure(session: s, credential: credential)
            return
        }
        do {
            _ = try await webViewForSubmit.evaluateJavaScript(submitScript)
        } catch {
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            browserViewModel?.showToast("Submit failed — skipping \(credential.username)")
            advanceAfterFailure(session: s, credential: credential)
            return
        }

        // Optional extra submits (sure-login). Paused while in-flight. The
        // page is checked after every extra submit — a permanent disable,
        // temp-disable, or success stops further submits immediately.
        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let baseDelay = rawDelay > 0 ? rawDelay : 1.5
        let delay = max(0.2, baseDelay * activeSpeedProfile.submitGapMultiplier)
        if extraCount > 0 {
            // The extra-submit loop is self-driving (state check after every
            // submit) and can legitimately run for ~50s — the watchdog must
            // not fire during it. It re-arms when the loop finishes.
            cancelRCRWatchdog(for: s)
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                await waitIfPausedOrFrozen(s)
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                try? await Task.sleep(for: .seconds(delay))
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                _ = try? await s.webView?.evaluateJavaScript(submitScript)

                try? await Task.sleep(for: .seconds(0.35))
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                let rawState = try? await s.webView?.evaluateJavaScript(
                    JavaScriptInjectionService.pageStateSnapshotScript()
                )
                if let payload = JavaScriptInjectionService.parsePageState(rawState),
                   JavaScriptInjectionService.isTerminalRCRState(payload) {
                    s.rcrExtraSubmitsInFlight = false
                    s.rcrStatus = .waiting
                    handleRCRMessage(session: s, payload: payload)
                    return
                }
            }
            s.rcrExtraSubmitsInFlight = false
        }

        credential.lastUsedAt = Date()
        credential.usageCount += 1
        try? modelContext?.save()

        // Pre-record pending.
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: targetDomain,
                sessionTag: s.sessionTag,
                status: .pending
            )
        }

        s.rcrStatus = .waiting
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript()
        _ = try? await s.webView?.evaluateJavaScript(installScript)
        armRCRWatchdog(for: s)
    }

    /// Entry point for the WKScriptMessageHandler — routes to the normal
    /// 4-way handler or the dual-quad paired-lane handler.
    func handleRCRMessage(session s: QuadSession, payload: [String: Any]) {
        if dualQuadActive {
            handleDualQuadMessage(session: s, payload: payload)
            return
        }
        guard s.rcrRunning, s.rcrStatus == .waiting else { return }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrJudging { return }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            Task { await self.runCurrent(session: s) }
            return
        }

        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        let signal = SuccessJudgeEngine.classifyLocal(payload)

        switch signal {
        case .disabled:
            applyLocalDisabled(session: s, credential: credential, password: password)
        case .tempDisabled:
            applyLocalTempDisabled(session: s, credential: credential, password: password)
        case .stillOnLogin:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            advanceAfterFailure(session: s, credential: credential)
        case .apparentSuccess, .unclear:
            s.rcrJudging = true
            cancelRCRWatchdog(for: s)
            let credID = credential.id
            Task {
                await self.judgeAndAdvance(session: s, payload: payload, credentialID: credID, password: password)
                s.rcrJudging = false
            }
        }
    }

    private func applyLocalDisabled(session s: QuadSession, credential: Credential, password: String) {
        ParkedSessionStore.shared.recordFailure()
        PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
        captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
        NeedsReviewStore.shared.flag(
            credentialID: credential.id,
            username: credential.username,
            domain: credential.domain,
            reason: "Showed as disabled during a run"
        )
        let completedID = credential.id
        Task { await self.burnAndAdvance(session: s, completedID: completedID) }
    }

    private func applyLocalTempDisabled(session s: QuadSession, credential: Credential, password: String) {
        captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
        if s.rcrPasswords.count > 1 {
            TempDisabledStore.shared.markDisabled(credentialID: credential.id)
            browserViewModel?.showToast("Temp-disabled — \(credential.username)")
        }
        s.rcrCompletedIDs.insert(credential.id)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        Task { await self.runCurrent(session: s) }
    }

    private func advanceAfterFailure(session s: QuadSession, credential: Credential) {
        if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
            s.rcrPasswordIndex += 1
            Task { await self.attemptFill(session: s) }
        } else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
        }
    }

    private func judgeAndAdvance(
        session s: QuadSession,
        payload: [String: Any],
        credentialID: String,
        password: String
    ) async {
        guard s.rcrRunning else { return }
        guard let credential = currentCredential(s), credential.id == credentialID else { return }
        // Speed-scaled grace before judging so the page settles into its
        // final state — slower profiles judge later, never sooner.
        try? await Task.sleep(for: activeSpeedProfile.judgeGrace)
        guard s.rcrRunning else { return }
        let image = await WebViewSnapshotter.capture(s.webView)
        let filename: String?
        if let image {
            filename = await ScreenshotStorage.save(image)
        } else {
            filename = nil
        }
        let domain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let decision = await SuccessJudgeEngine.judge(
            payload: payload,
            image: image,
            domain: domain,
            sessionTag: s.sessionTag
        )
        recordOutcome(
            session: s,
            credential: credential,
            password: password,
            status: decision.status,
            filename: filename,
            judge: decision
        )

        switch decision.status {
        case .disabled:
            applyLocalDisabled(session: s, credential: credential, password: password)
        case .tempDisabled:
            applyLocalTempDisabled(session: s, credential: credential, password: password)
        case .failed, .pending, .skipped:
            ParkedSessionStore.shared.recordFailure()
            advanceAfterFailure(session: s, credential: credential)
        case .review:
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
        case .success:
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            if decision.shouldPark {
                parkSession(s, credential: credential, thumbnail: image)
                if s.rcrIndex >= s.rcrTotal {
                    s.rcrRunning = false
                    s.rcrStatus = .finished
                    checkAllFinished()
                    return
                }
                s.rcrAwaitingNavigation = true
                s.rcrStatus = .navigating
                armRCRWatchdog(for: s)
            } else {
                Task { await self.runCurrent(session: s) }
            }
        }
    }

    func parkSession(_ s: QuadSession, credential: Credential, thumbnail: UIImage?) {
        // A saved login's cookie jar should only ever hold what the real
        // site set — never the diagnostics overlay's own bookkeeping cookie.
        WindowDiagnosticsService.shared.stripDiagnosticArtifacts(storeID: s.storeID)
        _ = ParkedSessionStore.shared.park(
            storeID: s.storeID,
            url: s.webView?.url ?? s.url,
            username: credential.username,
            domain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
            credentialID: credential.id,
            sessionTag: s.sessionTag,
            thumbnail: thumbnail,
            sourceWindowIndex: s.index
        )
        s.adoptFreshStore()
        s.url = s.rcrTargetURL
    }

    func recordOutcome(
        session s: QuadSession,
        credential: Credential,
        password: String,
        status: AttemptRecord.Status,
        filename: String?,
        judge: SuccessJudgeEngine.Decision?
    ) {
        guard let context = modelContext else { return }
        _ = AttemptTrackingService.shared.recordAttempt(
            context: context,
            credentialID: credential.id,
            username: credential.username,
            password: password,
            passwordIndex: s.rcrPasswordIndex + 1,
            passwordTotal: s.rcrPasswords.count,
            targetDomain: s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
            sessionTag: s.sessionTag,
            status: status,
            resultURL: s.webView?.url?.absoluteString,
            resultPageTitle: s.webView?.title,
            screenshotFilename: filename,
            judge: judge
        )
    }

    private func burnAndAdvance(session s: QuadSession, completedID: String) async {
        s.rcrStatus = .burning
        s.rcrBurnFlash &+= 1
        WindowDiagnosticsService.shared.noteBurn(session: s)
        if !ParkedSessionStore.shared.contains(storeID: s.storeID) {
            await QuadDataStore.burn(dataStoreID: s.storeID)
        }
        s.rcrCompletedIDs.insert(completedID)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        s.needsPostBurnSettle = true
        if let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            armRCRWatchdog(for: s, timeout: PageSettleService.postBurnNavigationWatchdog)
            return
        }
        await runCurrent(session: s)
    }

    func cellPageDidFinish(session s: QuadSession) {
        guard s.rcrRunning else { return }
        if s.rcrAwaitingNavigation {
            s.rcrAwaitingNavigation = false
            // Navigation leg completed — attemptFill arms the observation
            // watchdog once the submit is out.
            cancelRCRWatchdog(for: s)
            // Cookie popups only ever appear on a window's first load or
            // right after a burn+reload — both land here. After a perm-
            // disabled burn the next credential gets extra boot + consent
            // time so the login form is actually ready before we fill.
            Task {
                await self.settleThenFill(session: s)
            }
            return
        }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrStatus == .waiting || s.rcrStatus == .submitting {
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrInstallObserverScript(),
                completionHandler: nil
            )
            // A reload during observation gets a fresh watchdog window so a
            // dead reload can't stall the run.
            armRCRWatchdog(for: s)
        }
    }

    /// After a navigation finishes: wait for cookie/consent (and, after a
    /// burn, extra page-boot + login-form time) then start the fill. Also
    /// applies the site-smart pacing pause (learned settle, scaled by the
    /// live speed profile, plus a brief human-like pre-fill pause).
    private func settleThenFill(session s: QuadSession) async {
        let extra = s.needsPostBurnSettle
        s.needsPostBurnSettle = false
        let settleStart = Date()
        await waitForCookieNoticeIfNeeded(session: s, extraBoot: extra)
        guard s.rcrRunning else { return }
        if extra, let webView = s.webView {
            await PageSettleService.waitForLoginForm(in: webView)
            guard s.rcrRunning else { return }
        }
        // Learn how long this site really took to settle (bounded EMA),
        // then rest for the profile-scaled learned time before filling.
        let domain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        if !domain.isEmpty {
            let observed = Date().timeIntervalSince(settleStart)
            SitePacingStore.shared.recordSettle(seconds: observed, domain: domain)
            let learned = SitePacingStore.shared.settleSeconds(for: domain)
            let scaled = SpeedProfile.scaledSettle(baseSeconds: learned, profile: activeSpeedProfile)
            try? await Task.sleep(for: .seconds(scaled))
            guard s.rcrRunning else { return }
            let humanPause = SitePacingStore.shared.humanPauseSeconds(for: domain)
            try? await Task.sleep(for: .seconds(humanPause))
            guard s.rcrRunning else { return }
        }
        if dualQuadActive {
            await attemptFillDual(session: s, lane: laneIndex(for: s))
        } else {
            await attemptFill(session: s)
        }
    }

    /// Waits for a cookie/consent banner to appear and be dismissed.
    /// After a burn, gives the page extra time to boot and the CMP extra
    /// time to inject before concluding there is no banner.
    private func waitForCookieNoticeIfNeeded(session s: QuadSession, extraBoot: Bool) async {
        guard let webView = s.webView else { return }
        if extraBoot {
            try? await Task.sleep(for: PageSettleService.postBurnBootDelay)
            guard s.rcrRunning else { return }
        }
        let grace = extraBoot ? PageSettleService.postBurnCookieGraceMs : PageSettleService.normalCookieGraceMs
        let timeout = extraBoot ? PageSettleService.postBurnCookieTimeoutMs : PageSettleService.normalCookieTimeoutMs
        _ = try? await webView.evaluateJavaScript(
            JavaScriptInjectionService.waitForCookieNoticeScript(timeoutMs: timeout, graceMs: grace)
        )
    }

    private func checkAllFinished() {
        let allDone = enabledSessions.allSatisfy { !$0.rcrRunning }
        guard allDone else { return }
        let totalSuccess = enabledSessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = enabledSessions.reduce(0) { $0 + $1.rcrTotal }
        ParkedSessionStore.shared.markRunFinished()
        browserViewModel?.showToast("Quad RCR complete — \(totalSuccess) hits / \(totalTried) tried")
        browserViewModel?.offerNeedsReviewSummaryIfNeeded()
    }

    func captureAndRecord(
        session s: QuadSession,
        credential: Credential,
        password: String,
        status: AttemptRecord.Status
    ) {
        guard let context = modelContext else { return }
        let webView = s.webView
        let pageURL = webView?.url?.absoluteString
        let pageTitle = webView?.title
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let pwIndex = s.rcrPasswordIndex + 1
        let pwTotal = s.rcrPasswords.count
        let credID = credential.id
        let username = credential.username
        let tag = s.sessionTag

        if let webView {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 600
            webView.takeSnapshot(with: config) { image, _ in
                guard let image else {
                    Task { @MainActor in
                        _ = AttemptTrackingService.shared.recordAttempt(
                            context: context,
                            credentialID: credID,
                            username: username,
                            password: password,
                            passwordIndex: pwIndex,
                            passwordTotal: pwTotal,
                            targetDomain: targetDomain,
                            sessionTag: tag,
                            status: status,
                            resultURL: pageURL,
                            resultPageTitle: pageTitle,
                            screenshotFilename: nil
                        )
                    }
                    return
                }
                Task { @MainActor in
                    let filename = await ScreenshotStorage.save(image)
                    let record = AttemptTrackingService.shared.recordAttempt(
                        context: context,
                        credentialID: credID,
                        username: username,
                        password: password,
                        passwordIndex: pwIndex,
                        passwordTotal: pwTotal,
                        targetDomain: targetDomain,
                        sessionTag: tag,
                        status: status,
                        resultURL: pageURL,
                        resultPageTitle: pageTitle,
                        screenshotFilename: filename
                    )
                    // We must not capture the non-Sendable ModelContext or
                    // the @Model record inside a detached task (Swift 6
                    // isolation error). Keep everything here on the main
                    // actor; `classify` hops off-actor internally for the
                    // Vision work.
                    let result = await ScreenshotOCRService.classify(image)
                    record.ocrCategory = result.category.rawValue
                    try? context.save()
                }
            }
        } else {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credID,
                username: username,
                password: password,
                passwordIndex: pwIndex,
                passwordTotal: pwTotal,
                targetDomain: targetDomain,
                sessionTag: tag,
                status: status,
                resultURL: pageURL,
                resultPageTitle: pageTitle,
                screenshotFilename: nil
            )
        }
    }

}

/// Bounds-checked subscript. Internal rather than file-private because the
/// dual-site run logic lives in `QuadController+DualSite.swift` and leans on
/// it heavily when reading lane arrays.
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Settle box for one `callAsyncJavaScript` round trip. Lets the mirroring
/// engine put a hard timeout on a call that WebKit may never complete (wedged
/// web content process), while guaranteeing a late completion handler can
/// never resume anything twice.
@MainActor
private final class FollowLeaderCallBox {
    var isSettled: Bool = false
    /// The safety timeout, cancelled the moment a real result arrives so a
    /// completed action leaves nothing sleeping behind it.
    var watchdog: Task<Void, Never>?
}

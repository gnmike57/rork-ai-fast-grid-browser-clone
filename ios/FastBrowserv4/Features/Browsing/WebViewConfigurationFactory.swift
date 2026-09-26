import UIKit
import WebKit
import os

@MainActor
final class WebViewConfigurationFactory {
    private static let log = Logger(subsystem: "com.fastfill.browser", category: "WebViewConfiguration")
    static let shared = WebViewConfigurationFactory()
    
    private(set) var contentRuleList: WKContentRuleList?
    private(set) var isReady: Bool = false
    /// One process pool per data-store identity so tabs/windows cannot share
    /// in-memory WebKit process state (in addition to cookie/cache isolation).
    private var processPools: [UUID: WKProcessPool] = [:]

    private init() {}

    func prepare() async {
        await compileContentRules()
        isReady = true
    }

    /// Single-tab browsing with an isolated, persistent data store.
    func makeConfiguration(dataStoreID: UUID) -> WKWebViewConfiguration {
        makeIsolatedConfiguration(dataStoreID: dataStoreID, multiWindowViewport: false)
    }

    /// Multi-window entry point: isolated store + tile viewport normalization
    /// so every grid size (2×2, 2×3, 4×2, 3×3, 3×4, 4×4) renders a full-width page shrunk
    /// to fit its tile instead of a squished mini layout.
    func makeIsolatedConfiguration(dataStoreID: UUID) -> WKWebViewConfiguration {
        makeIsolatedConfiguration(dataStoreID: dataStoreID, multiWindowViewport: true)
    }

    private func makeIsolatedConfiguration(
        dataStoreID: UUID,
        multiWindowViewport: Bool
    ) -> WKWebViewConfiguration {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID)
        let config = makeConfiguration(dataStore: store, processPoolID: dataStoreID)

        if multiWindowViewport {
            let rawWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            let referenceWidth = Int(max(320, rawWidth).rounded())
            let viewportScript = WKUserScript(
                source: JavaScriptInjectionService.multiWindowViewportScript(referenceWidth: referenceWidth),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(viewportScript)
        }

        return config
    }

    private func processPool(for id: UUID) -> WKProcessPool {
        if let existing = processPools[id] { return existing }
        let pool = WKProcessPool()
        processPools[id] = pool
        return pool
    }

    private func makeConfiguration(
        dataStore: WKWebsiteDataStore,
        processPoolID: UUID
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.processPool = processPool(for: processPoolID)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let detectScript = WKUserScript(
            source: JavaScriptInjectionService.detectLoginFormScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(detectScript)

        let helperScript = WKUserScript(
            source: JavaScriptInjectionService.fillHelperScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(helperScript)

        // Cookie banner removal — injected at document end so it runs
        // after the initial DOM but before most page JS completes.
        let cookieScript = WKUserScript(
            source: JavaScriptInjectionService.cookieBannerRemovalScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(cookieScript)

        // Fingerprint hardening — injected at document start so they
        // override APIs before any page script can read them.
        let fontScript = WKUserScript(
            source: JavaScriptInjectionService.fontSpoofingScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(fontScript)

        let sensorScript = WKUserScript(
            source: JavaScriptInjectionService.sensorBlockingScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(sensorScript)

        let scrollScript = WKUserScript(
            source: JavaScriptInjectionService.humanScrollSimulationScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(scrollScript)

        // Follow the Leader recorder — document start, all frames. Installed
        // everywhere but inert until a window is armed as the leader, so an
        // action taken in the first moments of a page load is captured
        // instead of lost while the page finishes settling.
        let followLeaderScript = WKUserScript(
            source: JavaScriptInjectionService.followLeaderRecorderSource(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(followLeaderScript)

        if let ruleList = contentRuleList {
            config.userContentController.add(ruleList)
        }

        return config
    }

    /// Drops the cached process pool for a closed/burned identity so the next
    /// WebView for that slot starts completely clean.
    func releaseProcessPool(for dataStoreID: UUID) {
        processPools.removeValue(forKey: dataStoreID)
    }

    private func compileContentRules() async {
        let rules = """
        [
            {"trigger":{"url-filter":".*","resource-type":["script"],"url-filter-is-case-sensitive":false,"if-domain":["*doubleclick.net","*googlesyndication.com","*googleadservices.com","*google-analytics.com","*facebook.net","*facebook.com/tr","*analytics.google.com"]},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*","resource-type":["script","image","raw"],"url-filter-is-case-sensitive":false,"if-domain":["*hotjar.com","*mixpanel.com","*segment.io","*amplitude.com","*optimizely.com","*crazyegg.com","*mouseflow.com","*fullstory.com"]},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*\\\\.ads\\\\..*"},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*track(ing|er).*","resource-type":["script","raw"]},"action":{"type":"block"}}
        ]
        """

        do {
            contentRuleList = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "FastFillBlocker",
                encodedContentRuleList: rules
            )
        } catch {
            // A broken rule set must be diagnosable — silent failure means
            // all tracking protection silently disappears.
            Self.log.error("Content rule compilation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

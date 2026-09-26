import Foundation

/// Pure leak-check scoring used by the live overlay and unit tests.
/// iOS cannot report true per-WebView RSS, so these checks prove isolation,
/// burn wipe, and process pressure with signals we can actually observe.
nonisolated enum WindowLeakCheckEvaluator {
    static let isolationCookiePrefix = "__ffb_iso_"
    static let warnAvailableBytes: UInt64 = 80 * 1_048_576
    static let failAvailableBytes: UInt64 = 40 * 1_048_576

    static func overall(from items: [LeakCheckItem]) -> LeakCheckVerdict {
        items.map(\.verdict).max(by: { $0.rank < $1.rank }) ?? .idle
    }

    static func isolationCookieName(for index: Int) -> String {
        "\(isolationCookiePrefix)\(index)"
    }

    static func storeIdentityItem(
        sessionIndex: Int,
        storeID: UUID,
        expectedID: UUID,
        allStoreIDs: [UUID]
    ) -> LeakCheckItem {
        if storeID != expectedID {
            return LeakCheckItem(
                id: "store-id",
                name: "Store identity",
                verdict: .fail,
                detail: "S\(sessionIndex + 1) store UUID does not match its dedicated slot."
            )
        }
        let copies = allStoreIDs.filter { $0 == storeID }.count
        if copies != 1 {
            return LeakCheckItem(
                id: "store-id",
                name: "Store identity",
                verdict: .fail,
                detail: "S\(sessionIndex + 1) store is shared by \(copies) windows."
            )
        }
        if Set(allStoreIDs).count != allStoreIDs.count {
            return LeakCheckItem(
                id: "store-id",
                name: "Store identity",
                verdict: .fail,
                detail: "Two windows are sharing a data store."
            )
        }
        return LeakCheckItem(
            id: "store-id",
            name: "Store identity",
            verdict: .pass,
            detail: "S\(sessionIndex + 1) has a unique isolated store."
        )
    }

    static func cookieIsolationItem(
        sessionIndex: Int,
        token: String?,
        storesHoldingToken: [Int]
    ) -> LeakCheckItem {
        guard let token, !token.isEmpty else {
            return LeakCheckItem(
                id: "cookie-iso",
                name: "Cookie isolation",
                verdict: .warn,
                detail: "No isolation probe cookie yet — waiting for a loaded page."
            )
        }
        let others = storesHoldingToken.filter { $0 != sessionIndex }
        if !others.isEmpty {
            let labels = others.map { "S\($0 + 1)" }.joined(separator: ", ")
            return LeakCheckItem(
                id: "cookie-iso",
                name: "Cookie isolation",
                verdict: .fail,
                detail: "Probe cookie leaked into \(labels)."
            )
        }
        if !storesHoldingToken.contains(sessionIndex) {
            return LeakCheckItem(
                id: "cookie-iso",
                name: "Cookie isolation",
                verdict: .warn,
                detail: "Probe cookie was not retained in this window's store."
            )
        }
        return LeakCheckItem(
            id: "cookie-iso",
            name: "Cookie isolation",
            verdict: .pass,
            detail: "Probe cookie stayed inside S\(sessionIndex + 1)."
        )
    }

    static func burnWipeItem(
        sessionIndex: Int,
        didBurn: Bool,
        tokenStillPresent: Bool
    ) -> LeakCheckItem? {
        guard didBurn else { return nil }
        if tokenStillPresent {
            return LeakCheckItem(
                id: "burn-wipe",
                name: "Burn wipe",
                verdict: .fail,
                detail: "S\(sessionIndex + 1) still has pre-burn cookies after a wipe."
            )
        }
        return LeakCheckItem(
            id: "burn-wipe",
            name: "Burn wipe",
            verdict: .pass,
            detail: "Pre-burn isolation cookie was cleared."
        )
    }

    static func memoryReboundItem(
        sessionIndex: Int,
        preBurnBytes: UInt64?,
        currentBytes: UInt64
    ) -> LeakCheckItem? {
        guard let preBurnBytes, preBurnBytes > 0 else { return nil }
        if currentBytes > preBurnBytes &* 3 {
            return LeakCheckItem(
                id: "mem-rebound",
                name: "Memory rebound",
                verdict: .fail,
                detail: "S\(sessionIndex + 1) estimate grew past 3× the pre-burn footprint."
            )
        }
        if currentBytes > preBurnBytes + preBurnBytes / 2 {
            return LeakCheckItem(
                id: "mem-rebound",
                name: "Memory rebound",
                verdict: .warn,
                detail: "S\(sessionIndex + 1) estimate is still well above the pre-burn level."
            )
        }
        return LeakCheckItem(
            id: "mem-rebound",
            name: "Memory rebound",
            verdict: .pass,
            detail: "Post-burn estimate did not keep climbing."
        )
    }

    static func processPressureItem(availableBytes: UInt64) -> LeakCheckItem {
        if availableBytes > 0, availableBytes < failAvailableBytes {
            return LeakCheckItem(
                id: "pressure",
                name: "Process pressure",
                verdict: .fail,
                detail: "Only \(ProcessMemorySampler.formatBytes(availableBytes)) left for the app."
            )
        }
        if availableBytes > 0, availableBytes < warnAvailableBytes {
            return LeakCheckItem(
                id: "pressure",
                name: "Process pressure",
                verdict: .warn,
                detail: "\(ProcessMemorySampler.formatBytes(availableBytes)) remaining — 16 windows may jetsam."
            )
        }
        return LeakCheckItem(
            id: "pressure",
            name: "Process pressure",
            verdict: .pass,
            detail: availableBytes == 0
                ? "Available memory was not reported."
                : "\(ProcessMemorySampler.formatBytes(availableBytes)) still available."
        )
    }

    static func webViewItem(sessionIndex: Int, hasWebView: Bool, isActive: Bool) -> LeakCheckItem {
        if isActive && !hasWebView {
            return LeakCheckItem(
                id: "webview",
                name: "WebView",
                verdict: .warn,
                detail: "S\(sessionIndex + 1) is active but has no live WebView yet."
            )
        }
        return LeakCheckItem(
            id: "webview",
            name: "WebView",
            verdict: .pass,
            detail: hasWebView ? "Live WebView is attached." : "Slot is dormant."
        )
    }

    static func report(from items: [LeakCheckItem], checkedAt: Date = .now) -> WindowLeakCheckReport {
        WindowLeakCheckReport(verdict: overall(from: items), items: items, checkedAt: checkedAt)
    }
}

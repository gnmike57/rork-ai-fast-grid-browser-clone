import Foundation
import Testing
@testable import FastBrowserv4

struct WindowDiagnosticsTests {

    @Test
    func formatBytesUsesReadableUnits() {
        #expect(ProcessMemorySampler.formatBytes(512) == "512 B")
        #expect(ProcessMemorySampler.formatBytes(2_048) == "2 KB")
        #expect(ProcessMemorySampler.compactBytes(1_572_864) == "1.5M")
        #expect(ProcessMemorySampler.compactBytes(52_428_800) == "50M")
    }

    @Test
    func pageMetricsParseFromJSONString() {
        let metrics = WindowDiagnosticsService.parsePageMetrics(
            "{\"htmlBytes\":1200,\"nodes\":40,\"images\":3,\"iframes\":1,\"scripts\":2}"
        )
        #expect(metrics.htmlBytes == 1200)
        #expect(metrics.nodeCount == 40)
        #expect(metrics.imageCount == 3)
        #expect(metrics.iframeCount == 1)
        #expect(metrics.scriptCount == 2)
        #expect(metrics.weight > 0)
    }

    @Test
    func overallVerdictTakesWorstResult() {
        let items = [
            LeakCheckItem(id: "a", name: "A", verdict: .pass, detail: "ok"),
            LeakCheckItem(id: "b", name: "B", verdict: .warn, detail: "maybe"),
            LeakCheckItem(id: "c", name: "C", verdict: .fail, detail: "bad")
        ]
        #expect(WindowLeakCheckEvaluator.overall(from: items) == .fail)
        #expect(WindowLeakCheckEvaluator.report(from: Array(items.prefix(2))).verdict == .warn)
        #expect(WindowLeakCheckEvaluator.overall(from: []) == .idle)
    }

    @Test
    func storeIdentityFailsWhenWindowsShareAStore() {
        let shared = UUID()
        let item = WindowLeakCheckEvaluator.storeIdentityItem(
            sessionIndex: 0,
            storeID: shared,
            expectedID: shared,
            allStoreIDs: [shared, shared]
        )
        #expect(item.verdict == .fail)
    }

    @Test @MainActor
    func uniqueStoresPassIdentityCheck() {
        let a = QuadDataStore.identifier(for: 0)
        let b = QuadDataStore.identifier(for: 1)
        let item = WindowLeakCheckEvaluator.storeIdentityItem(
            sessionIndex: 0,
            storeID: a,
            expectedID: a,
            allStoreIDs: [a, b]
        )
        #expect(item.verdict == .pass)
    }

    @Test
    func cookieIsolationDetectsCrossWindowLeak() {
        let leaked = WindowLeakCheckEvaluator.cookieIsolationItem(
            sessionIndex: 0,
            token: "abc",
            storesHoldingToken: [0, 3]
        )
        #expect(leaked.verdict == .fail)

        let isolated = WindowLeakCheckEvaluator.cookieIsolationItem(
            sessionIndex: 0,
            token: "abc",
            storesHoldingToken: [0]
        )
        #expect(isolated.verdict == .pass)
    }

    @Test
    func burnWipeFailsOnlyWhenOldTokenSurvives() {
        let failed = WindowLeakCheckEvaluator.burnWipeItem(
            sessionIndex: 2,
            didBurn: true,
            tokenStillPresent: true
        )
        #expect(failed?.verdict == .fail)

        let passed = WindowLeakCheckEvaluator.burnWipeItem(
            sessionIndex: 2,
            didBurn: true,
            tokenStillPresent: false
        )
        #expect(passed?.verdict == .pass)
        #expect(WindowLeakCheckEvaluator.burnWipeItem(sessionIndex: 2, didBurn: false, tokenStillPresent: false) == nil)
    }

    @Test
    func memoryReboundAndPressureThresholds() {
        let failRebound = WindowLeakCheckEvaluator.memoryReboundItem(
            sessionIndex: 1,
            preBurnBytes: 10_000_000,
            currentBytes: 40_000_000
        )
        #expect(failRebound?.verdict == .fail)

        let warnPressure = WindowLeakCheckEvaluator.processPressureItem(availableBytes: 50 * 1_048_576)
        #expect(warnPressure.verdict == .warn)

        let failPressure = WindowLeakCheckEvaluator.processPressureItem(availableBytes: 10 * 1_048_576)
        #expect(failPressure.verdict == .fail)
    }

    @Test @MainActor
    func sixteenWindowsEachHaveUniqueStoresForLeakCheck() {
        let ids = (0..<16).map { QuadDataStore.identifier(for: $0) }
        #expect(Set(ids).count == 16)
        for index in 0..<16 {
            let item = WindowLeakCheckEvaluator.storeIdentityItem(
                sessionIndex: index,
                storeID: ids[index],
                expectedID: QuadDataStore.identifier(for: index),
                allStoreIDs: ids
            )
            #expect(item.verdict == .pass)
        }
    }
}

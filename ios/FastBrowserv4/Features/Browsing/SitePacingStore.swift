import Foundation

/// Learns how long each site really needs after a page load before its
/// login form is fillable (some sites take longer — consent banners,
/// slow boot after a burned store). The estimate is bounded so one weird
/// page can never poison or stall pacing forever, and it persists across
/// launches. Also derives the brief human-like pause taken before filling.
@MainActor
final class SitePacingStore {
    static let shared = SitePacingStore()
    private init() {}

    nonisolated static let minSettleSeconds: Double = 0.6
    nonisolated static let maxSettleSeconds: Double = 12.0
    nonisolated static let defaultSettleSeconds: Double = 1.5
    /// Learning rate: new = old·(1−rate) + observed·rate.
    nonisolated static let learningRate: Double = 0.3
    /// Observed values are clamped before learning so outliers can't warp
    /// the estimate.
    nonisolated static let minObservedSeconds: Double = 0.2
    nonisolated static let maxObservedSeconds: Double = 30.0

    private static let storageKey = "sitePacingSettleV1"

    private var store: [String: Double] =
        UserDefaults.standard.dictionary(forKey: SitePacingStore.storageKey) as? [String: Double] ?? [:]

    /// Learned post-load settle time for a domain, in seconds.
    func settleSeconds(for domain: String) -> Double {
        store[normalized(domain)] ?? Self.defaultSettleSeconds
    }

    /// True once this domain has a learned estimate.
    func hasLearned(for domain: String) -> Bool {
        store[normalized(domain)] != nil
    }

    /// Feeds an observed settle time into the learning estimate.
    func recordSettle(seconds: Double, domain: String) {
        let observed = Self.clamp(seconds, Self.minObservedSeconds, Self.maxObservedSeconds)
        let current = settleSeconds(for: domain)
        let learned = Self.learnedEstimate(current: current, observed: observed)
        store[normalized(domain)] = learned
        persist()
    }

    /// Brief human-like pause before filling, derived from the learned settle.
    func humanPauseSeconds(for domain: String) -> Double {
        Self.clamp(settleSeconds(for: domain) * 0.2, 0.1, 0.8)
    }

    func reset(domain: String) {
        store.removeValue(forKey: normalized(domain))
        persist()
    }

    func resetAll() {
        store.removeAll()
        persist()
    }

    /// All learned pairs for the settings card, sorted by domain.
    func allLearned() -> [(domain: String, seconds: Double)] {
        store.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    nonisolated static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(value, lo), hi)
    }

    /// Pure learning step: bounded EMA of the observed settle time.
    nonisolated static func learnedEstimate(current: Double, observed: Double) -> Double {
        let c = clamp(current, minSettleSeconds, maxSettleSeconds)
        let o = clamp(observed, minObservedSeconds, maxObservedSeconds)
        return clamp(c * (1 - learningRate) + o * learningRate, minSettleSeconds, maxSettleSeconds)
    }

    private nonisolated func normalized(_ domain: String) -> String {
        domain.lowercased()
    }

    private func persist() {
        UserDefaults.standard.set(store, forKey: Self.storageKey)
    }
}

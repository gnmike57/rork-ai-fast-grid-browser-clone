import Foundation
import SwiftData
import OSLog
import FoundationModels
import UIKit

/// Errors the router can surface. Deliberately terse — internal provider
/// details are logged, never thrown upward.
nonisolated enum IntelligenceError: Error, Sendable {
    case brainUnavailable
    case noKeysConfigured
    case malformedReply
    case allBrainsFailed
    /// A single brain attempt exceeded its time budget (stall guard).
    case timedOut
    /// The whole ask exceeded its total budget across all brain attempts.
    case totalTimedOut
}

/// Central router for every AI decision in the app. Picks the right "brain"
/// for a job (Apple on-device → Apple Private Cloud Compute → the user's own
/// API keys), rotates multiple keys per provider, cools down keys that hit
/// rate limits, and falls over to the next brain automatically.
///
/// Privacy rule enforced here: callers only ever pass page *structure* and
/// *text* — never passwords, never field values.
@MainActor
@Observable
final class IntelligenceCenter {
    static let shared = IntelligenceCenter()

    // MARK: - Types

    /// Which brain serves a job.
    nonisolated enum AIBrain: String, CaseIterable, Identifiable, Sendable {
        case rorkCloud
        case onDevice
        case appleCloud
        case byokKey

        var id: String { rawValue }

        var label: String {
            switch self {
            case .rorkCloud: return "Rork Cloud"
            case .onDevice: return "On-device"
            case .appleCloud: return "Apple Cloud"
            case .byokKey: return "Your API keys"
            }
        }
    }

    /// Jobs with distinct routing preferences.
    nonisolated enum AIJob: String, CaseIterable, Identifiable, Sendable {
        /// Fast, frequent checks (fill verification summaries, small calls).
        case quick
        /// Login success/failure verdicts.
        case verdict
        /// Selector repair — the hardest reasoning in the app.
        case heal

        var id: String { rawValue }

        var label: String {
            switch self {
            case .quick: return "Quick checks"
            case .verdict: return "Login verdicts"
            case .heal: return "Fill repair"
            }
        }

        var settingsKey: String { "aiRoute.\(rawValue)" }

        var `default`: AIBrain {
            // Rork AI Cloud is the out-of-the-box default for every job —
            // no setup, no keys. On-device Apple Intelligence is the
            // offline fallback; BYOK remains available under Advanced.
            switch self {
            case .quick: return .rorkCloud
            case .verdict: return .rorkCloud
            case .heal: return .rorkCloud
            }
        }
    }

    nonisolated struct AIAnswer: Sendable {
        var text: String
        var brain: AIBrain
        /// Human-readable detail, e.g. "OpenAI · key 2/3".
        var brainDetail: String
    }

    private static let logger = Logger(subsystem: "FastFill", category: "Intelligence")

    // MARK: - State

    private(set) var onDeviceAvailable: Bool = false
    private(set) var onDeviceNote: String = "Checking…"
    private(set) var appleCloudAvailable: Bool = false
    private(set) var appleCloudNote: String = "Checking…"
    private(set) var rorkCloudAvailable: Bool = false
    private(set) var rorkCloudNote: String = "Checking…"

    /// Active BYOK providers (enabled only), sorted by sortOrder.
    private(set) var providers: [AIProviderConfig] = []

    private var modelContext: ModelContext?
    private let client = OpenAIChatClient()

    /// Key-level cooldowns, in-memory only: "<providerID>:<slot>" → until.
    private var cooldownUntil: [String: Date] = [:]

    private init() {}

    // MARK: - Wiring

    /// Called once from the browser view model after it receives a context.
    func attach(context: ModelContext) {
        modelContext = context
        refreshProviders()
        refreshAvailability()
    }

    func refreshProviders() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<AIProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? modelContext.fetch(descriptor)) ?? []
        providers = all.filter { $0.isEnabled }
    }

    var hasUsableKeys: Bool {
        providers.contains { $0.keyCount > 0 }
    }

    /// The Rork Cloud model every job uses by default.
    nonisolated static let rorkCloudModel = "google/gemini-2.5-flash"

    /// Re-polls Apple model availability (on-device + Private Cloud Compute)
    /// and the Rork Cloud wiring. Cheap; call on settings open and app
    /// foreground.
    func refreshAvailability() {
        let onDevice = SystemLanguageModel.default
        switch onDevice.availability {
        case .available:
            onDeviceAvailable = true
            onDeviceNote = "Ready"
        case .unavailable(let reason):
            onDeviceAvailable = false
            onDeviceNote = Self.reasonText(reason)
        }

        // Rork AI Cloud is available when the build injected the toolkit
        // endpoint and its delegated secret. The values are empty in source
        // and filled in by the build pipeline.
        let toolkitBase = Config.EXPO_PUBLIC_TOOLKIT_URL.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolkitSecret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY.trimmingCharacters(in: .whitespacesAndNewlines)
        rorkCloudAvailable = !toolkitBase.isEmpty && !toolkitSecret.isEmpty
        rorkCloudNote = rorkCloudAvailable
            ? "Ready — built-in, no setup"
            : "Unavailable on this build"

        // Private Cloud Compute is real on iOS 27. It needs Apple
        // Intelligence (same device/region prerequisite as the on-device
        // model) plus a network connection and the managed PCC entitlement.
        // The full integration lives in `AppleCloudBrain`, compiled in behind
        // FASTFILL_PCC_SDK (defined only when the toolchain has the iOS 27
        // SDK — see project.pbxproj). On the current iOS 26 SDK the symbol
        // doesn't exist, so the brain reports honestly and the router falls
        // over to on-device / your keys instead of pretending.
        if #available(iOS 27.0, *) {
            #if FASTFILL_PCC_SDK
            appleCloudAvailable = onDeviceAvailable
            appleCloudNote = onDeviceAvailable
                ? "Ready — Apple's server model"
                : "Needs Apple Intelligence turned on"
            #else
            appleCloudAvailable = false
            appleCloudNote = "Not available — requires iOS 27"
            #endif
        } else {
            appleCloudAvailable = false
            appleCloudNote = "Not available — requires iOS 27"
        }
    }

    private static func reasonText(_ reason: Any) -> String {
        // Availability reasons differ between models; describe generically.
        let raw = String(describing: reason)
        switch raw {
        case "deviceNotEligible": return "This device isn't eligible"
        case "appleIntelligenceNotEnabled": return "Turn on Apple Intelligence in Settings"
        case "modelNotReady", "systemNotReady": return "Model is preparing — try again shortly"
        default: return "Unavailable (\(raw))"
        }
    }

    // MARK: - Routing

    func preferredBrain(for job: AIJob) -> AIBrain {
        let raw = UserDefaults.standard.string(forKey: job.settingsKey) ?? job.default.rawValue
        return AIBrain(rawValue: raw) ?? job.default
    }

    /// Preferred brain first, then the remaining brains in a canonical
    /// privacy-first order (Rork Cloud → on-device → Apple Cloud → BYOK),
    /// filtered to those that can actually serve today.
    nonisolated static func attemptOrder(
        preferred: AIBrain,
        rorkOK: Bool,
        onDeviceOK: Bool,
        cloudOK: Bool,
        keysOK: Bool
    ) -> [AIBrain] {
        var order: [AIBrain] = [preferred]
        for brain in [AIBrain.rorkCloud, .onDevice, .appleCloud, .byokKey] where !order.contains(brain) {
            order.append(brain)
        }
        return order.filter { brain in
            switch brain {
            case .rorkCloud: return rorkOK
            case .onDevice: return onDeviceOK
            case .appleCloud: return cloudOK
            case .byokKey: return keysOK
            }
        }
    }

    // MARK: - Asking

    /// Routes a text question to the best available brain for the job,
    /// escalating automatically on failure. Throws `allBrainsFailed` only
    /// after every configured brain has been tried.
    func ask(job: AIJob, system: String, user: String) async throws -> AIAnswer {
        try await ask(job: job, system: system, user: user, imageJPEG: nil)
    }

    /// Same as `ask`, optionally attaching a JPEG screenshot. Passwords must
    /// never be in the image or the prompt. Apple brains use native picture
    /// input on an iOS 27 SDK build and fall back to the text prompt (which
    /// already includes OCR) on the current toolchain.
    ///
    /// Stall guards: each brain attempt gets its own time budget and the
    /// whole ask a total budget, so a wedged provider can never freeze a
    /// run — it times out, fails over to the next brain, and finally
    /// surfaces `totalTimedOut` so callers fall back to local judgement.
    func ask(job: AIJob, system: String, user: String, imageJPEG: Data?) async throws -> AIAnswer {
        do {
            return try await withTimeout(Self.totalAskBudget) {
                try await self.askWithinBudget(job: job, system: system, user: user, imageJPEG: imageJPEG)
            }
        } catch IntelligenceError.timedOut {
            throw IntelligenceError.totalTimedOut
        }
    }

    /// Per-attempt and per-brain time budgets for the stall guards.
    nonisolated static let brainAttemptBudget: Duration = .seconds(15)
    nonisolated static let totalAskBudget: Duration = .seconds(30)

    private func askWithinBudget(
        job: AIJob,
        system: String,
        user: String,
        imageJPEG: Data?
    ) async throws -> AIAnswer {
        refreshProviders()
        let order = Self.attemptOrder(
            preferred: preferredBrain(for: job),
            rorkOK: rorkCloudAvailable,
            onDeviceOK: onDeviceAvailable,
            cloudOK: appleCloudAvailable,
            keysOK: hasUsableKeys
        )
        var lastError: Error = IntelligenceError.allBrainsFailed
        for brain in order {
            do {
                let text: String
                let detail: String
                switch brain {
                case .rorkCloud:
                    (text, detail) = try await withTimeout(Self.brainAttemptBudget) {
                        let answer = try await self.askRorkCloud(system: system, user: user, imageJPEG: imageJPEG)
                        return (answer, "Rork Cloud")
                    }
                case .onDevice:
                    (text, detail) = try await withTimeout(Self.brainAttemptBudget) {
                        let answer = try await self.askApple(cloud: false, system: system, user: user, imageJPEG: imageJPEG)
                        return (answer, "On-device")
                    }
                case .appleCloud:
                    (text, detail) = try await withTimeout(Self.brainAttemptBudget) {
                        let answer = try await self.askApple(cloud: true, system: system, user: user, imageJPEG: imageJPEG)
                        return (answer, "Apple Cloud")
                    }
                case .byokKey:
                    (text, detail) = try await withTimeout(Self.brainAttemptBudget) {
                        try await self.askBYOK(system: system, user: user, imageJPEG: imageJPEG)
                    }
                }
                return AIAnswer(text: text, brain: brain, brainDetail: detail)
            } catch {
                Self.logger.log("Brain \(brain.rawValue, privacy: .public) failed for job \(job.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Races `operation` against `budget`; the budget expiring wins with
    /// `IntelligenceError.timedOut` and cancels the losing operation.
    private func withTimeout<T: Sendable>(
        _ budget: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: budget)
                throw IntelligenceError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw IntelligenceError.timedOut
            }
            return result
        }
    }

    // MARK: - Rork AI Cloud brain

    /// The app's built-in brain: Gemini 2.5 Flash through the Rork toolkit
    /// proxy (OpenAI-compatible chat endpoint). Uses the build-injected
    /// endpoint + delegated secret; costs ride the project's cloud credits.
    private func askRorkCloud(system: String, user: String, imageJPEG: Data?) async throws -> String {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !secret.isEmpty else {
            throw IntelligenceError.brainUnavailable
        }
        return try await client.chat(
            system: system,
            user: user,
            imageJPEG: imageJPEG,
            endpoint: .init(
                baseURL: base + "/v2/vercel/v1",
                apiKey: secret,
                model: Self.rorkCloudModel
            )
        )
    }

    /// Asks for a JSON reply and decodes it. On a malformed reply, retries
    /// once with a sharper instruction before failing over.
    func askJSON<T: Decodable & Sendable>(job: AIJob, system: String, user: String, as type: T.Type) async throws -> (T, AIAnswer) {
        try await askJSON(job: job, system: system, user: user, imageJPEG: nil, as: type)
    }

    /// Total budget for a JSON ask including its one retry — keeps the
    /// judge/heal stall guard tight even when a malformed reply forces the
    /// sharper retry prompt.
    nonisolated static let jsonAskBudget: Duration = .seconds(45)

    func askJSON<T: Decodable & Sendable>(
        job: AIJob,
        system: String,
        user: String,
        imageJPEG: Data?,
        as type: T.Type
    ) async throws -> (T, AIAnswer) {
        try await withTimeout(Self.jsonAskBudget) {
            var answer = try await self.ask(job: job, system: system + Self.jsonContract, user: user, imageJPEG: imageJPEG)
            if let value = Self.decodeJSON(T.self, from: answer.text) {
                return (value, answer)
            }
            answer = try await self.ask(
                job: job,
                system: system + Self.jsonContract + "\nYour previous reply was not valid JSON. Reply with ONLY the JSON object.",
                user: user,
                imageJPEG: imageJPEG
            )
            guard let value = Self.decodeJSON(T.self, from: answer.text) else {
                throw IntelligenceError.malformedReply
            }
            return (value, answer)
        }
    }

    private static let jsonContract = """

    Reply with ONLY a single JSON object. No markdown, no code fences, no commentary.
    """

    // MARK: - Apple brains (on-device + Private Cloud Compute)

    private func askApple(cloud: Bool, system: String, user: String, imageJPEG: Data?) async throws -> String {
        if cloud {
            guard #available(iOS 27.0, *), appleCloudAvailable else {
                throw IntelligenceError.brainUnavailable
            }
            return try await AppleCloudBrain.respond(system: system, user: user, imageJPEG: imageJPEG)
        }
        guard onDeviceAvailable else { throw IntelligenceError.brainUnavailable }
        return try await respondOnDevice(system: system, user: user, imageJPEG: imageJPEG)
    }

    private func respondOnDevice(system: String, user: String, imageJPEG: Data?) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        #if FASTFILL_PCC_SDK
        if #available(iOS 27.0, *), let imageJPEG, let image = UIImage(data: imageJPEG), let cg = image.cgImage {
            return try await session.respond {
                user
                Attachment(cg)
            }.content
        }
        #endif
        return try await session.respond(to: user).content
    }

    // MARK: - BYOK brain

    /// Walks enabled providers in user order; within a provider, rotates key
    /// slots round-robin, skipping keys in cooldown. Rate-limit and 5xx
    /// responses cool the key for 2 minutes; unauthorized for 1 hour.
    private func askBYOK(system: String, user: String, imageJPEG: Data? = nil) async throws -> (String, String) {
        guard hasUsableKeys else { throw IntelligenceError.noKeysConfigured }
        var lastError: Error = IntelligenceError.noKeysConfigured

        for provider in providers where provider.keyCount > 0 {
            var slot = provider.rotationIndex % provider.keyCount
            var tried = 0
            while tried < provider.keyCount {
                defer { tried += 1 }
                let cooldownKey = "\(provider.id):\(slot)"
                if let until = cooldownUntil[cooldownKey], until > Date() {
                    slot = (slot + 1) % provider.keyCount
                    continue
                }
                guard let apiKey = LLMKeyVault.shared.key(providerID: provider.id, slot: slot) else {
                    slot = (slot + 1) % provider.keyCount
                    continue
                }
                do {
                    let text = try await client.chat(
                        system: system,
                        user: user,
                        imageJPEG: imageJPEG,
                        endpoint: .init(baseURL: provider.baseURL, apiKey: apiKey, model: provider.modelName)
                    )
                    provider.rotationIndex = (slot + 1) % provider.keyCount
                    try? modelContext?.save()
                    return (text, "\(provider.displayName) · key \(slot + 1)/\(provider.keyCount)")
                } catch let error as LLMClientError {
                    lastError = error
                    if error.isRotatable {
                        cooldownUntil[cooldownKey] = Date().addingTimeInterval(120)
                    }
                    if error == .unauthorized {
                        cooldownUntil[cooldownKey] = Date().addingTimeInterval(3600)
                    }
                    slot = (slot + 1) % provider.keyCount
                } catch {
                    lastError = error
                    slot = (slot + 1) % provider.keyCount
                }
            }
        }
        throw lastError
    }

    // MARK: - Key slot utilities (pure — unit-tested)

    /// Round-robin slot picker that skips cooled-down keys. `cooling` holds
    /// the slots currently in cooldown. Returns nil when every slot is cold.
    nonisolated static func pickSlot(keyCount: Int, startAt: Int, cooling: Set<Int>) -> Int? {
        guard keyCount > 0 else { return nil }
        var slot = startAt % keyCount
        for _ in 0..<keyCount {
            if !cooling.contains(slot) { return slot }
            slot = (slot + 1) % keyCount
        }
        return nil
    }

    // MARK: - JSON extraction (pure — unit-tested)

    /// Extracts a JSON object substring from a chatty model reply — strips
    /// code fences and leading/trailing prose.
    nonisolated static func extractJSONObject(from text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines).filter { !$0.hasPrefix("```") }
            trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let open = trimmed.firstIndex(of: "{"),
              let close = trimmed.lastIndex(of: "}"),
              open < close else { return nil }
        return String(trimmed[open...close])
    }

    nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - AI run log

    /// Appends a plain-English entry to the AI run log (Settings →
    /// Intelligence → Activity).
    func log(kind: String, domain: String, sessionTag: String, brain: String, summary: String, succeeded: Bool) {
        guard let modelContext else { return }
        modelContext.insert(AIRepairEvent(
            domain: domain,
            sessionTag: sessionTag,
            kind: kind,
            brain: brain,
            summary: summary,
            succeeded: succeeded
        ))
        try? modelContext.save()
    }
}

/// Real Apple Private Cloud Compute integration (iOS 27+). Isolated in its
/// own availability-gated type so the rest of the app compiles on iOS 26 and
/// this brain activates automatically for iOS 27 users on a build made with
/// the iOS 27 SDK.
@available(iOS 27.0, *)
enum AppleCloudBrain {
    static func respond(system: String, user: String) async throws -> String {
        #if FASTFILL_PCC_SDK
        // Real Private Cloud Compute call. One-line model swap vs. the
        // on-device session — same unified FoundationModels API.
        return try await respond(system: system, user: user, imageJPEG: nil)
        #else
        throw IntelligenceError.brainUnavailable
        #endif
    }

    static func respond(system: String, user: String, imageJPEG: Data?) async throws -> String {
        #if FASTFILL_PCC_SDK
        let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
        if let imageJPEG, let image = UIImage(data: imageJPEG), let cg = image.cgImage {
            return try await session.respond {
                system + "\n\n" + user
                Attachment(cg)
            }.content
        }
        let combined = system + "\n\n" + user
        return try await session.respond(to: combined).content
        #else
        throw IntelligenceError.brainUnavailable
        #endif
    }
}

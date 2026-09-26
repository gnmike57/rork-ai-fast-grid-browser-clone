import Foundation
import UIKit

/// Local-first login judgement. Instant DOM signals run first; the screenshot
/// OCR is next; the AI is spent only where it changes the outcome — confirming
/// an apparent success before parking, or correcting a genuinely unclear page.
/// Passwords are never part of any prompt.
enum SuccessJudgeEngine {

    enum DetectionMode: String, CaseIterable, Identifiable, Sendable {
        case local
        case localAndAI
        case localAIVision

        var id: String { rawValue }

        var label: String {
            switch self {
            case .local: return "Local only"
            case .localAndAI: return "Local + AI"
            case .localAIVision: return "Local + AI + picture"
            }
        }

        var settingsKey: String { "aiSuccessDetectionMode" }

        static var current: DetectionMode {
            let raw = UserDefaults.standard.string(forKey: DetectionMode.local.settingsKey) ?? DetectionMode.localAndAI.rawValue
            return DetectionMode(rawValue: raw) ?? .localAndAI
        }
    }

    enum LocalSignal: String, Sendable {
        case apparentSuccess
        case disabled
        case tempDisabled
        case stillOnLogin
        case unclear
    }

    nonisolated struct Decision: Sendable {
        var status: AttemptRecord.Status
        var verdict: String
        var confidence: Double
        var reason: String
        var source: String
        var brain: String
        var shouldPark: Bool
        var ocrCategory: String?

        nonisolated static func local(
            status: AttemptRecord.Status,
            verdict: String,
            confidence: Double,
            reason: String,
            shouldPark: Bool = false,
            ocrCategory: String? = nil
        ) -> Decision {
            Decision(
                status: status,
                verdict: verdict,
                confidence: confidence,
                reason: reason,
                source: "local",
                brain: "—",
                shouldPark: shouldPark,
                ocrCategory: ocrCategory
            )
        }
    }

    nonisolated struct AIVerdict: Decodable, Sendable {
        var verdict: String?
        var confidence: Double?
        var reason: String?
    }

    /// Builds the picture-judgement prompt. Pure so tests can assert we never
    /// ask for a password and we only attach an image on ambiguous pages.
    enum VisionRequest {
        nonisolated static let systemPrompt = """
        You judge whether a web login succeeded. You receive local page signals, \
        on-device OCR of a screenshot, and optionally the screenshot itself. \
        Values of form fields and passwords are never included and you must never \
        ask for them. Reply with ONLY a JSON object: \
        {"verdict":"confirmed"|"review"|"failed"|"disabled","confidence":0.0-1.0,"reason":"short plain English"}. \
        Use confirmed only when the page is clearly a signed-in account or home. \
        Use disabled when the account is locked or permanently blocked. \
        Use failed for wrong-password / still-on-login / captcha. \
        Use review when you are not sure.
        """

        nonisolated static func userPrompt(
            domain: String,
            url: String,
            local: LocalSignal,
            ocrCategory: String,
            ocrText: String,
            hasImage: Bool
        ) -> String {
            let clipped = String(ocrText.prefix(1200))
            let imageNote = hasImage
                ? "A screenshot of the page is attached. Use it. It contains no typed passwords."
                : "No screenshot is attached — judge from the signals and OCR text only."
            return """
            Domain: \(domain)
            URL: \(url)
            Local signal: \(local.rawValue)
            OCR category: \(ocrCategory)
            Visible text (OCR, may be empty): \(clipped)
            \(imageNote)
            """
        }

        /// Picture understanding is reserved for genuinely ambiguous pages,
        /// and only after the user has consented.
        nonisolated static func shouldAttachImage(
            mode: DetectionMode,
            local: LocalSignal,
            ocr: ScreenshotOCRService.Category,
            consent: Bool
        ) -> Bool {
            guard consent, mode == .localAIVision else { return false }
            if local == .disabled || local == .tempDisabled || local == .stillOnLogin {
                return false
            }
            if local == .unclear && ocr == .unknown { return true }
            if local == .apparentSuccess && ocr == .unknown { return true }
            if local == .apparentSuccess && ocr == .failure { return true }
            return false
        }
    }

    // MARK: - Local classification (pure)

    nonisolated static func classifyLocal(_ payload: [String: Any]) -> LocalSignal {
        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let hasError = payload["hasError"] as? Bool ?? false
        let hasCaptcha = payload["hasCaptcha"] as? Bool ?? false
        let hasTwoFactor = payload["hasTwoFactor"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false

        // Hard account states win over everything else on the page.
        if hasDisabled { return .disabled }
        if hasTempDisabled { return .tempDisabled }

        // A 2FA / OTP challenge means the password was accepted — the page only
        // asks for a second factor once the first one passed. That is the
        // strongest "these credentials are valid" signal short of a landed
        // session, so treat it as apparent success (confirmed/reviewed, never
        // discarded), unless the page is simultaneously showing an error.
        if hasTwoFactor && !hasError { return .apparentSuccess }

        // A visible error banner or a captcha wall on a page that still has a
        // password field means this submit was rejected or blocked — this
        // password did not get us in, so advance to the next one.
        if (hasError || hasCaptcha) && hasPassword { return .stillOnLogin }

        // Positive signals: a greeting, an explicit success marker, or a bare
        // homepage with no login form and nothing blocking it.
        if hasWelcome || hasSuccess || (isHomepage && !hasPassword && !hasCaptcha) { return .apparentSuccess }

        // A lone captcha or error with no password field is genuinely
        // ambiguous — hand it to OCR/AI rather than guessing.
        if hasCaptcha || hasError { return .unclear }

        if hasPassword { return .stillOnLogin }
        return .unclear
    }

    /// Instant local decisions that must never wait on AI.
    nonisolated static func localOnlyDecision(for signal: LocalSignal) -> Decision? {
        switch signal {
        case .disabled:
            return .local(
                status: .disabled,
                verdict: "local",
                confidence: 1,
                reason: "The page says this account has been disabled."
            )
        case .tempDisabled:
            return .local(
                status: .tempDisabled,
                verdict: "local",
                confidence: 0.95,
                reason: "The page says this account is temporarily locked."
            )
        case .stillOnLogin:
            return .local(
                status: .failed,
                verdict: "local",
                confidence: 0.9,
                reason: "Still on the login form — this password did not work."
            )
        case .apparentSuccess, .unclear:
            return nil
        }
    }

    /// Combines local signal + OCR into a decision when AI is off or has not
    /// yet answered. Conflicts become `.review` rather than a guess.
    nonisolated static func combineLocalAndOCR(
        signal: LocalSignal,
        ocr: ScreenshotOCRService.Category,
        mode: DetectionMode
    ) -> Decision {
        if let locked = ocrLockedDecision(ocr) { return locked }

        switch signal {
        case .disabled, .tempDisabled, .stillOnLogin:
            return localOnlyDecision(for: signal) ?? .local(
                status: .failed, verdict: "local", confidence: 0.5, reason: "Local signal."
            )
        case .apparentSuccess:
            if ocr == .failure {
                return .local(
                    status: .review,
                    verdict: "review",
                    confidence: 0.45,
                    reason: "The page looked successful, but the screenshot reads as a failed login."
                )
            }
            if ocr == .captcha {
                return .local(
                    status: .failed,
                    verdict: "local",
                    confidence: 0.85,
                    reason: "A captcha appeared after submit — not treating this as a login."
                )
            }
            if mode == .local {
                return .local(
                    status: .success,
                    verdict: "confirmed",
                    confidence: ocr == .success ? 0.85 : 0.7,
                    reason: ocr == .success
                        ? "Local success signals and the screenshot agree."
                        : "Local success signals — picture check is off.",
                    shouldPark: true
                )
            }
            return .local(
                status: .review,
                verdict: "review",
                confidence: 0.55,
                reason: "Looks successful — waiting on AI confirmation before parking."
            )
        case .unclear:
            if ocr == .success && mode == .local {
                return .local(
                    status: .success,
                    verdict: "confirmed",
                    confidence: 0.7,
                    reason: "The screenshot looks like a signed-in page.",
                    shouldPark: true
                )
            }
            if ocr == .failure || ocr == .captcha {
                return .local(
                    status: .failed,
                    verdict: "local",
                    confidence: 0.8,
                    reason: ocr == .captcha
                        ? "The screenshot is a captcha or security check."
                        : "The screenshot reads as a failed login."
                )
            }
            return .local(
                status: .review,
                verdict: "review",
                confidence: 0.4,
                reason: "The page is unclear — flagged for review rather than guessed."
            )
        }
    }

    nonisolated static func ocrLockedDecision(_ ocr: ScreenshotOCRService.Category) -> Decision? {
        if ocr == .locked {
            return .local(
                status: .disabled,
                verdict: "local",
                confidence: 0.9,
                reason: "The screenshot says this account is locked or suspended."
            )
        }
        return nil
    }

    /// Applies an AI JSON reply on top of the local+OCR baseline. Low
    /// confidence or a missing verdict stays on review — we never park on a
    /// guess.
    nonisolated static func applyAI(
        baseline: Decision,
        reply: AIVerdict,
        brain: String,
        usedVision: Bool
    ) -> Decision {
        let raw = (reply.verdict ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let confidence = min(max(reply.confidence ?? 0, 0), 1)
        let reason = (reply.reason?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "AI judgement."
        let source = usedVision ? "vision" : "ai"

        switch raw {
        case "confirmed":
            if confidence >= 0.7 {
                return Decision(
                    status: .success,
                    verdict: "confirmed",
                    confidence: confidence,
                    reason: reason,
                    source: source,
                    brain: brain,
                    shouldPark: true,
                    ocrCategory: baseline.ocrCategory
                )
            }
            return Decision(
                status: .review,
                verdict: "review",
                confidence: confidence,
                reason: "AI leaned success but wasn't sure enough to park. \(reason)",
                source: source,
                brain: brain,
                shouldPark: false,
                ocrCategory: baseline.ocrCategory
            )
        case "failed":
            return Decision(
                status: .failed,
                verdict: "failed",
                confidence: max(confidence, 0.55),
                reason: reason,
                source: source,
                brain: brain,
                shouldPark: false,
                ocrCategory: baseline.ocrCategory
            )
        case "disabled":
            return Decision(
                status: .disabled,
                verdict: "disabled",
                confidence: max(confidence, 0.6),
                reason: reason,
                source: source,
                brain: brain,
                shouldPark: false,
                ocrCategory: baseline.ocrCategory
            )
        case "review":
            return Decision(
                status: .review,
                verdict: "review",
                confidence: confidence,
                reason: reason,
                source: source,
                brain: brain,
                shouldPark: false,
                ocrCategory: baseline.ocrCategory
            )
        default:
            var kept = baseline
            kept.brain = brain
            kept.source = source
            kept.reason = "AI reply was unclear — keeping the local reading. \(kept.reason)"
            kept.shouldPark = false
            if kept.status == .success { kept.status = .review; kept.verdict = "review" }
            return kept
        }
    }

    /// True when this page is worth an AI call: apparent success (must
    /// confirm before parking) or a genuinely unclear / conflicting page.
    nonisolated static func shouldAskAI(
        mode: DetectionMode,
        signal: LocalSignal,
        ocr: ScreenshotOCRService.Category
    ) -> Bool {
        guard mode != .local else { return false }
        if signal == .disabled || signal == .tempDisabled || signal == .stillOnLogin {
            return false
        }
        if ocr == .locked || ocr == .captcha { return false }
        if signal == .apparentSuccess { return true }
        if signal == .unclear { return true }
        return false
    }

    static var visionConsentGranted: Bool {
        UserDefaults.standard.bool(forKey: "aiVisionConsentGranted")
    }

    static func setVisionConsent(_ granted: Bool) {
        UserDefaults.standard.set(granted, forKey: "aiVisionConsentGranted")
    }

    // MARK: - Live judgement

    /// Full cascade used by the runner. `image` is the post-submit snapshot;
    /// it is never required. Passwords must not be passed in.
    @MainActor
    static func judge(
        payload: [String: Any],
        image: UIImage?,
        domain: String,
        sessionTag: String
    ) async -> Decision {
        let signal = classifyLocal(payload)
        if let immediate = localOnlyDecision(for: signal) {
            return immediate
        }

        let mode = DetectionMode.current
        var ocrCategory: ScreenshotOCRService.Category = .unknown
        var ocrText = ""
        if let image {
            let result = await ScreenshotOCRService.classify(image)
            ocrCategory = result.category
            ocrText = result.allText
        }

        if var locked = ocrLockedDecision(ocrCategory) {
            locked.ocrCategory = ocrCategory.rawValue
            return locked
        }

        var baseline = combineLocalAndOCR(signal: signal, ocr: ocrCategory, mode: mode)
        baseline.ocrCategory = ocrCategory.rawValue
        guard shouldAskAI(mode: mode, signal: signal, ocr: ocrCategory) else {
            return baseline
        }

        let consent = visionConsentGranted
        let attach = VisionRequest.shouldAttachImage(
            mode: mode,
            local: signal,
            ocr: ocrCategory,
            consent: consent
        )
        let jpeg: Data? = {
            guard attach, let image else { return nil }
            return image.jpegData(compressionQuality: 0.55)
        }()

        let url = payload["url"] as? String ?? ""
        let user = VisionRequest.userPrompt(
            domain: domain,
            url: url,
            local: signal,
            ocrCategory: ocrCategory.rawValue,
            ocrText: ocrText,
            hasImage: jpeg != nil
        )

        do {
            let (reply, answer) = try await IntelligenceCenter.shared.askJSON(
                job: .verdict,
                system: VisionRequest.systemPrompt,
                user: user,
                imageJPEG: jpeg,
                as: AIVerdict.self
            )
            let decision = applyAI(
                baseline: baseline,
                reply: reply,
                brain: answer.brainDetail,
                usedVision: jpeg != nil
            )
            IntelligenceCenter.shared.log(
                kind: "judge",
                domain: domain,
                sessionTag: sessionTag,
                brain: answer.brainDetail,
                summary: decision.reason,
                succeeded: decision.shouldPark || decision.status == .success
            )
            var stamped = decision
            stamped.ocrCategory = ocrCategory.rawValue
            return stamped
        } catch {
            var fallback = baseline
            fallback.shouldPark = false
            if fallback.status == .success {
                fallback.status = .review
                fallback.verdict = "review"
            }
            fallback.reason = "No AI brain answered — flagged for review instead of guessing. \(fallback.reason)"
            IntelligenceCenter.shared.log(
                kind: "judge",
                domain: domain,
                sessionTag: sessionTag,
                brain: "—",
                summary: fallback.reason,
                succeeded: false
            )
            fallback.ocrCategory = ocrCategory.rawValue
            return fallback
        }
    }
}

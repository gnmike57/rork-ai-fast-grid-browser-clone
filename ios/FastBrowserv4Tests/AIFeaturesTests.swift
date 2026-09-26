import Testing
import Foundation
@testable import FastBrowserv4

struct AIFeaturesTests {

    // MARK: - Local cascade

    @Test
    func classifyLocal_disabledBeatsEverything() {
        let payload: [String: Any] = [
            "hasDisabled": true,
            "hasWelcome": true,
            "hasPassword": true
        ]
        #expect(SuccessJudgeEngine.classifyLocal(payload) == .disabled)
    }

    @Test
    func classifyLocal_apparentSuccessFromWelcomeOrHomepage() {
        #expect(SuccessJudgeEngine.classifyLocal([
            "hasWelcome": true, "hasPassword": false
        ]) == .apparentSuccess)
        #expect(SuccessJudgeEngine.classifyLocal([
            "isHomepage": true, "hasPassword": false
        ]) == .apparentSuccess)
    }

    @Test
    func classifyLocal_stillOnLoginWhenPasswordFieldRemains() {
        #expect(SuccessJudgeEngine.classifyLocal([
            "hasPassword": true
        ]) == .stillOnLogin)
    }

    @Test
    func classifyLocal_unclearWhenNoSignals() {
        #expect(SuccessJudgeEngine.classifyLocal([:]) == .unclear)
    }

    @Test
    func localOnlyDecision_skipsAIForClearFailures() {
        #expect(SuccessJudgeEngine.localOnlyDecision(for: .disabled)?.status == .disabled)
        #expect(SuccessJudgeEngine.localOnlyDecision(for: .tempDisabled)?.status == .tempDisabled)
        #expect(SuccessJudgeEngine.localOnlyDecision(for: .stillOnLogin)?.status == .failed)
        #expect(SuccessJudgeEngine.localOnlyDecision(for: .apparentSuccess) == nil)
        #expect(SuccessJudgeEngine.localOnlyDecision(for: .unclear) == nil)
    }

    @Test
    func combineLocalAndOCR_conflictBecomesReview() {
        let decision = SuccessJudgeEngine.combineLocalAndOCR(
            signal: .apparentSuccess,
            ocr: .failure,
            mode: .localAndAI
        )
        #expect(decision.status == .review)
        #expect(decision.shouldPark == false)
    }

    @Test
    func combineLocalAndOCR_localModeParksAgreedSuccess() {
        let decision = SuccessJudgeEngine.combineLocalAndOCR(
            signal: .apparentSuccess,
            ocr: .success,
            mode: .local
        )
        #expect(decision.status == .success)
        #expect(decision.shouldPark)
    }

    @Test
    func combineLocalAndOCR_aiModeDoesNotParkWithoutConfirm() {
        let decision = SuccessJudgeEngine.combineLocalAndOCR(
            signal: .apparentSuccess,
            ocr: .success,
            mode: .localAndAI
        )
        #expect(decision.shouldPark == false)
        #expect(decision.verdict == "review")
    }

    @Test
    func applyAI_confirmedHighConfidenceParks() {
        let baseline = SuccessJudgeEngine.Decision.local(
            status: .review,
            verdict: "review",
            confidence: 0.5,
            reason: "waiting"
        )
        let decision = SuccessJudgeEngine.applyAI(
            baseline: baseline,
            reply: .init(verdict: "confirmed", confidence: 0.9, reason: "Signed-in dashboard."),
            brain: "On-device",
            usedVision: false
        )
        #expect(decision.shouldPark)
        #expect(decision.status == .success)
        #expect(decision.verdict == "confirmed")
    }

    @Test
    func applyAI_lowConfidenceStaysReview() {
        let baseline = SuccessJudgeEngine.Decision.local(
            status: .review, verdict: "review", confidence: 0.5, reason: "waiting"
        )
        let decision = SuccessJudgeEngine.applyAI(
            baseline: baseline,
            reply: .init(verdict: "confirmed", confidence: 0.4, reason: "Maybe."),
            brain: "On-device",
            usedVision: false
        )
        #expect(decision.shouldPark == false)
        #expect(decision.status == .review)
    }

    @Test
    func shouldAskAI_onlyWhereItChangesTheOutcome() {
        #expect(SuccessJudgeEngine.shouldAskAI(mode: .local, signal: .apparentSuccess, ocr: .success) == false)
        #expect(SuccessJudgeEngine.shouldAskAI(mode: .localAndAI, signal: .stillOnLogin, ocr: .unknown) == false)
        #expect(SuccessJudgeEngine.shouldAskAI(mode: .localAndAI, signal: .disabled, ocr: .unknown) == false)
        #expect(SuccessJudgeEngine.shouldAskAI(mode: .localAndAI, signal: .apparentSuccess, ocr: .success))
        #expect(SuccessJudgeEngine.shouldAskAI(mode: .localAndAI, signal: .unclear, ocr: .unknown))
        #expect(SuccessJudgeEngine.shouldAskAI(mode: .localAndAI, signal: .unclear, ocr: .captcha) == false)
    }

    // MARK: - Vision request builder

    @Test
    func visionRequest_neverMentionsPasswords() {
        let prompt = SuccessJudgeEngine.VisionRequest.userPrompt(
            domain: "example.com",
            url: "https://example.com/account",
            local: .unclear,
            ocrCategory: "Unknown",
            ocrText: "My account  Deposit",
            hasImage: true
        )
        #expect(!prompt.lowercased().contains("password"))
        #expect(prompt.contains("example.com"))
        #expect(SuccessJudgeEngine.VisionRequest.systemPrompt.lowercased().contains("never"))
    }

    @Test
    func visionRequest_attachesImageOnlyOnAmbiguousConsentingPages() {
        #expect(SuccessJudgeEngine.VisionRequest.shouldAttachImage(
            mode: .localAIVision, local: .unclear, ocr: .unknown, consent: true
        ))
        #expect(SuccessJudgeEngine.VisionRequest.shouldAttachImage(
            mode: .localAIVision, local: .stillOnLogin, ocr: .unknown, consent: true
        ) == false)
        #expect(SuccessJudgeEngine.VisionRequest.shouldAttachImage(
            mode: .localAndAI, local: .unclear, ocr: .unknown, consent: true
        ) == false)
        #expect(SuccessJudgeEngine.VisionRequest.shouldAttachImage(
            mode: .localAIVision, local: .unclear, ocr: .unknown, consent: false
        ) == false)
    }

    // MARK: - Routing / PCC fallback

    @Test
    func attemptOrder_skipsUnavailableCloud() {
        let order = IntelligenceCenter.attemptOrder(
            preferred: .appleCloud,
            rorkOK: false,
            onDeviceOK: true,
            cloudOK: false,
            keysOK: true
        )
        #expect(!order.contains(.appleCloud))
        #expect(order.first == .onDevice)
        #expect(order.contains(.byokKey))
    }

    @Test
    func attemptOrder_preferredCloudFirstWhenReady() {
        let order = IntelligenceCenter.attemptOrder(
            preferred: .appleCloud,
            rorkOK: false,
            onDeviceOK: true,
            cloudOK: true,
            keysOK: false
        )
        #expect(order == [.appleCloud, .onDevice])
    }

    @Test
    func attemptOrder_rorkCloudIsDefaultFallback() {
        let order = IntelligenceCenter.attemptOrder(
            preferred: .onDevice,
            rorkOK: true,
            onDeviceOK: false,
            cloudOK: false,
            keysOK: false
        )
        #expect(order == [.rorkCloud])
    }

    @Test
    func extractJSONObject_stripsFencesAndProse() {
        let raw = """
        Sure.
        ```json
        {"verdict":"confirmed","confidence":0.9}
        ```
        """
        let json = IntelligenceCenter.extractJSONObject(from: raw)
        #expect(json?.contains("\"verdict\"") == true)
        let decoded = IntelligenceCenter.decodeJSON(SuccessJudgeEngine.AIVerdict.self, from: raw)
        #expect(decoded?.verdict == "confirmed")
    }

    // MARK: - Healer budget

    @Test @MainActor
    func healerBudget_resetsBetweenRuns() {
        UserDefaults.standard.set(true, forKey: "aiHealerEnabled")
        let engine = FillHealerEngine.shared
        engine.resetRunBudget()
        #expect(engine.usedHeals(for: "example.com") == 0)
        engine.resetRunBudget()
        #expect(engine.usedHeals(for: "example.com") == 0)
        #expect(engine.isEnabled)
        UserDefaults.standard.set(false, forKey: "aiHealerEnabled")
        #expect(!engine.isEnabled)
        UserDefaults.standard.removeObject(forKey: "aiHealerEnabled")
    }

    // MARK: - Parked session isolation

    @Test @MainActor
    func parkedSessions_keepDistinctStoreIdentities() {
        let a = UUID()
        let b = UUID()
        #expect(a != b)
        let first = ParkedSession(
            storeID: a,
            urlString: "https://a.example/account",
            username: "alice",
            domain: "a.example",
            credentialID: "1",
            sessionTag: "S1",
            thumbnailFilename: nil,
            sourceWindowIndex: 0
        )
        let second = ParkedSession(
            storeID: b,
            urlString: "https://b.example/account",
            username: "bob",
            domain: "b.example",
            credentialID: "2",
            sessionTag: "S2",
            thumbnailFilename: nil,
            sourceWindowIndex: 1
        )
        #expect(first.storeID != second.storeID)
        #expect(first.storeUUID == a)
        #expect(second.storeUUID == b)
    }

    @Test @MainActor
    func parkedSessionStore_containsMatchesExactStoreOnly() {
        let store = ParkedSessionStore.shared
        let missing = UUID()
        let holdsUnknownStore = store.contains(storeID: missing)
        #expect(!holdsUnknownStore)
    }
}

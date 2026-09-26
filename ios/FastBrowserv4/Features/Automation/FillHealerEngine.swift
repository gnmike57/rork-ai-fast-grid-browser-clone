import Foundation
import WebKit
import SwiftData

/// Self-healing auto-fill. When a fill comes back empty (site changed its
/// layout, fields renamed), the healer asks the routed AI brain for repaired
/// CSS selectors, verifies them against the live page, re-fills, and
/// remembers working selectors per website so the fix is instant next time.
///
/// Hard safety rails (by design, not by prompt):
/// - The AI only ever sees page STRUCTURE (types/names/labels/visibility) —
///   never values, never passwords.
/// - A password is only filled into a selector that probes as a real,
///   visible password-ish input.
/// - Captcha and lockout pages are detected locally and never fought.
/// - Retry budget: at most 2 heals per domain per session, so a batch can
///   never stall on an AI loop.
@MainActor
final class FillHealerEngine {
    static let shared = FillHealerEngine()
    private init() {}

    /// A verified repair: selectors that demonstrably filled the page.
    struct HealOutcome {
        let usernameSelector: String
        let passwordSelector: String
        let submitSelector: String?
        let explanation: String
        let brainLabel: String
    }

    // MARK: - DTOs (pure data, safe off-main)

    nonisolated struct SelectorFix: Decodable, Sendable {
        var usernameSelector: String?
        var passwordSelector: String?
        var submitSelector: String?
        var explanation: String?
    }

    nonisolated struct ProbeInfo: Decodable, Sendable {
        var found: Bool?
        var tag: String?
        var type: String?
        var name: String?
        var id: String?
        var placeholder: String?
        var visible: Bool?
    }

    nonisolated private struct Probes: Decodable, Sendable {
        var user: ProbeInfo?
        var pass: ProbeInfo?
        var submit: ProbeInfo?
    }

    nonisolated private struct FillResult: Decodable, Sendable {
        var filled: Int?
        var userFound: Bool?
        var passFound: Bool?
    }

    nonisolated private struct VerifyResult: Decodable, Sendable {
        var userFound: Bool?
        var passFound: Bool?
        var userFilled: Bool?
        var passFilled: Bool?
    }

    nonisolated struct PageOutline: Codable, Sendable {
        struct Field: Codable, Sendable {
            var index: Int?
            var tag: String?
            var type: String?
            var name: String?
            var id: String?
            var placeholder: String?
            var ariaLabel: String?
            var autocomplete: String?
            var labelText: String?
            var visible: Bool?
        }
        struct ButtonInfo: Codable, Sendable {
            var index: Int?
            var tag: String?
            var type: String?
            var id: String?
            var text: String?
            var visible: Bool?
        }
        var url: String?
        var title: String?
        var forms: Int?
        var inputs: [Field]?
        var buttons: [ButtonInfo]?
        var hasCaptcha: Bool?
        var hasLockout: Bool?
    }

    // MARK: - Retry budget

    /// In-memory per-domain retry budget — 2 heals per domain per app
    /// session. Deliberately not persisted: a fresh launch deserves fresh
    /// attempts.
    private var budget: [String: Int] = [:]
    nonisolated static let maxHealsPerDomain = 2

    func resetRunBudget() {
        budget.removeAll()
    }

    /// How many heals have been spent on this domain in the current run.
    func usedHeals(for domain: String) -> Int {
        budget[domain.lowercased(), default: 0]
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "aiHealerEnabled") as? Bool ?? true
    }

    // MARK: - Static interpretation helpers (pure, unit-tested)

    /// True when the fill script reports it couldn't find one or both fields.
    nonisolated static func fillMissed(_ raw: Any?) -> Bool {
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(FillResult.self, from: data) else { return false }
        return result.userFound != true || result.passFound != true
    }

    /// True when values are still sitting in the fields after a submit —
    /// the submit click didn't take effect.
    nonisolated static func fillIntact(_ raw: Any?) -> Bool {
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(VerifyResult.self, from: data) else { return false }
        return result.userFilled == true || result.passFilled == true
    }

    /// A healed username selector must hit a visible, non-password input.
    nonisolated static func userProbeOK(_ probe: ProbeInfo?) -> Bool {
        guard let probe, probe.found == true, probe.visible == true else { return false }
        guard (probe.tag ?? "") == "input" else { return false }
        return (probe.type ?? "") != "password"
    }

    /// A healed password selector must hit a visible password input — or a
    /// clearly password-named text input (some sites fake it), never anything
    /// else. This is the rail that stops passwords landing in search boxes.
    nonisolated static func passProbeOK(_ probe: ProbeInfo?) -> Bool {
        guard let probe, probe.found == true, probe.visible == true else { return false }
        guard (probe.tag ?? "") == "input" else { return false }
        let type = (probe.type ?? "").lowercased()
        if type == "password" { return true }
        guard type.isEmpty || type == "text" else { return false }
        let haystack = [probe.name, probe.id, probe.placeholder]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains("pass")
    }

    /// A healed submit selector must hit a visible clickable element.
    nonisolated static func submitProbeOK(_ probe: ProbeInfo?) -> Bool {
        guard let probe, probe.found == true, probe.visible == true else { return false }
        let tag = probe.tag ?? ""
        return !tag.isEmpty
    }

    // MARK: - The heal

    /// One-call gate for fill sites: checks the fill result, the enabled
    /// toggle, and the retry budget, then runs the full heal. Returns the
    /// verified repair (or nil). Safe to call from every RCR fill path.
    func healIfNeeded(
        webView: WKWebView,
        fillResult: Any?,
        domain: String,
        sessionTag: String,
        username: String,
        password: String,
        modelContext: ModelContext
    ) async -> HealOutcome? {
        guard Self.fillMissed(fillResult) else { return nil }
        return await healAndRefill(
            webView: webView,
            domain: domain,
            sessionTag: sessionTag,
            username: username,
            password: password,
            modelContext: modelContext
        )
    }

    /// Full repair cycle: outline → AI diagnosis → verify probes → refill →
    /// verify values landed → persist per site + log. Returns nil on ANY
    /// failure; callers keep their previous behavior untouched.
    func healAndRefill(
        webView: WKWebView,
        domain: String,
        sessionTag: String,
        username: String,
        password: String,
        modelContext: ModelContext
    ) async -> HealOutcome? {
        let center = IntelligenceCenter.shared
        let target = domain.lowercased()
        guard isEnabled else { return nil }
        let used = budget[target, default: 0]
        guard used < Self.maxHealsPerDomain else { return nil }
        budget[target] = used + 1

        // 1. Read the page OUTLINE (structure only — never values).
        guard let rawOutline = try? await webView.evaluateJavaScript(
            JavaScriptInjectionService.pageOutlineScript()
        ) as? String,
              let outlineData = rawOutline.data(using: .utf8),
              let outline = try? JSONDecoder().decode(PageOutline.self, from: outlineData)
        else { return nil }

        // Never fight captcha or lockout pages.
        if outline.hasCaptcha == true || outline.hasLockout == true {
            center.log(
                kind: "heal", domain: domain, sessionTag: sessionTag, brain: "—",
                summary: "Skipped repair — this page is a captcha or lockout screen; not fighting it.",
                succeeded: false
            )
            return nil
        }
        guard outline.inputs?.isEmpty == false else { return nil }

        // 2. Ask the routed brain for repaired selectors.
        let systemPrompt = """
        You repair a login auto-fill for a password browser. You receive a JSON outline of a web page's \
        STRUCTURE: input fields and clickable elements with their types, names, ids, placeholders and labels. \
        Values are never included and you must never ask for them. The generic selectors failed on this page. \
        Pick the best CSS selector for the username field, the password field, and the submit/login control. \
        Prefer stable selectors: #id first, then [name="…"] / [placeholder="…"] / [aria-label="…"]. \
        Only use elements that appear in the outline. If the page has no password input, set passwordSelector \
        to null (multi-step login). Keep each selector short and unambiguous.
        """

        let userPrompt: String
        if let compact = try? JSONEncoder().encode(outline),
           let compactText = String(data: compact, encoding: .utf8) {
            userPrompt = "Page outline for \(domain):\n\(compactText)"
        } else {
            return nil
        }

        let fix: SelectorFix
        let brainLabel: String
        do {
            let (value, answer) = try await center.askJSON(
                job: .heal,
                system: systemPrompt,
                user: userPrompt,
                as: SelectorFix.self
            )
            fix = value
            brainLabel = answer.brainDetail
        } catch {
            center.log(
                kind: "heal", domain: domain, sessionTag: sessionTag, brain: "—",
                summary: "Couldn't diagnose \(domain) — no AI brain answered (all routes unavailable).",
                succeeded: false
            )
            return nil
        }

        let explanation = fix.explanation ?? "Selector repair suggested."
        guard let userSel = fix.usernameSelector, !userSel.isEmpty,
              let passSel = fix.passwordSelector, !passSel.isEmpty else {
            center.log(
                kind: "heal", domain: domain, sessionTag: sessionTag, brain: brainLabel,
                summary: explanation, succeeded: false
            )
            return nil
        }
        let submitSel = (fix.submitSelector?.isEmpty == false) ? fix.submitSelector : nil

        // 3. Verify the suggested selectors BEFORE touching any secret.
        guard let rawProbe = try? await webView.evaluateJavaScript(
            JavaScriptInjectionService.selectorProbeScript(
                usernameSelector: userSel,
                passwordSelector: passSel,
                submitSelector: submitSel
            )
        ) as? String,
              let probeData = rawProbe.data(using: .utf8),
              let probes = try? JSONDecoder().decode(Probes.self, from: probeData)
        else { return nil }

        guard Self.userProbeOK(probes.user), Self.passProbeOK(probes.pass) else {
            center.log(
                kind: "heal", domain: domain, sessionTag: sessionTag, brain: brainLabel,
                summary: "Rejected the AI's selectors — safety check failed (suggested password target wasn't a real password field).",
                succeeded: false
            )
            return nil
        }
        let verifiedSubmitSel = Self.submitProbeOK(probes.submit) ? submitSel : nil

        // 4. Re-fill with the repaired selectors, then confirm values landed.
        let refill = JavaScriptInjectionService.fillCredentialScript(
            username: username,
            password: password,
            usernameSelector: userSel,
            passwordSelector: passSel,
            suppressKeyboard: true
        )
        _ = try? await webView.evaluateJavaScript(refill)
        guard let rawVerify = try? await webView.evaluateJavaScript(
            JavaScriptInjectionService.verifyFillScript(usernameSelector: userSel, passwordSelector: passSel)
        ) as? String,
              let verifyData = rawVerify.data(using: .utf8),
              let verify = try? JSONDecoder().decode(VerifyResult.self, from: verifyData),
              verify.userFilled == true, verify.passFilled == true
        else {
            center.log(
                kind: "heal", domain: domain, sessionTag: sessionTag, brain: brainLabel,
                summary: "Repair didn't stick — the fields were still empty after the AI's fix. \(explanation)",
                succeeded: false
            )
            return nil
        }

        // 5. Verified. Remember per site + leave a plain-English log entry.
        let outcome = HealOutcome(
            usernameSelector: userSel,
            passwordSelector: passSel,
            submitSelector: verifiedSubmitSel,
            explanation: explanation,
            brainLabel: brainLabel
        )
        persist(outcome: outcome, domain: target, modelContext: modelContext)
        center.log(
            kind: "heal", domain: domain, sessionTag: sessionTag, brain: brainLabel,
            summary: "Fixed a stuck fill: \(explanation)",
            succeeded: true
        )
        return outcome
    }

    /// Saves a verified repair into SiteSetting so future fills on this
    /// domain use the working selectors instantly, no AI call needed.
    private func persist(outcome: HealOutcome, domain: String, modelContext: ModelContext) {
        var descriptor = FetchDescriptor<SiteSetting>(predicate: #Predicate { $0.domain == domain })
        descriptor.fetchLimit = 1
        let setting: SiteSetting
        if let existing = try? modelContext.fetch(descriptor).first {
            setting = existing
        } else {
            setting = SiteSetting(domain: domain)
            modelContext.insert(setting)
        }
        setting.usernameSelector = outcome.usernameSelector
        setting.passwordSelector = outcome.passwordSelector
        if let submit = outcome.submitSelector {
            setting.submitButtonSelector = submit
        }
        setting.updatedAt = Date()
        try? modelContext.save()
    }
}

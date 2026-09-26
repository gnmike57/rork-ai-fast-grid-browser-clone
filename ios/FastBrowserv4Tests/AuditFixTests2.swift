//
//  AuditFixTests2.swift
//  FastBrowserv4Tests
//
//  Regression coverage for the second full-audit remediation pass:
//  the RCR message origin gate, query-aware target matching, JS string
//  escaping, the RCR start re-entrancy latch, and the toast generation fix.
//

import Testing
import Foundation
import SwiftData
@testable import FastBrowserv4

struct AuditFixTests2 {

    // MARK: - Origin gate (rcrObserver message forgery defense)

    @Test
    func originGate_acceptsExactWwwCaseAndSubdomainMatches() {
        #expect(BrowserViewModel.isTrustedRCROrigin("example.com", targetHost: "example.com"))
        #expect(BrowserViewModel.isTrustedRCROrigin("www.example.com", targetHost: "example.com"))
        #expect(BrowserViewModel.isTrustedRCROrigin("EXAMPLE.COM", targetHost: "example.com"))
        // Post-login redirects often land on a subdomain of the target.
        #expect(BrowserViewModel.isTrustedRCROrigin("account.example.com", targetHost: "example.com"))
        // Target stored with www-prefix, message from bare host.
        #expect(BrowserViewModel.isTrustedRCROrigin("example.com", targetHost: "www.example.com"))
    }

    @Test
    func originGate_rejectsForeignAndLookalikeHosts() {
        #expect(!BrowserViewModel.isTrustedRCROrigin("evil.com", targetHost: "example.com"))
        // Suffix attack: "notexample.com" must not match "example.com".
        #expect(!BrowserViewModel.isTrustedRCROrigin("notexample.com", targetHost: "example.com"))
        // Target host appearing as a subdomain prefix of a foreign host.
        #expect(!BrowserViewModel.isTrustedRCROrigin("example.com.evil.com", targetHost: "example.com"))
        #expect(!BrowserViewModel.isTrustedRCROrigin(nil, targetHost: "example.com"))
        #expect(!BrowserViewModel.isTrustedRCROrigin("example.com", targetHost: nil))
        #expect(!BrowserViewModel.isTrustedRCROrigin("", targetHost: "example.com"))
    }

    // MARK: - sameTarget (query-aware)

    @Test
    func sameTarget_distinguishesQueryStrings() {
        let base = URL(string: "https://example.com/login")!
        let withQuery = URL(string: "https://example.com/login?next=/home")!
        let otherQuery = URL(string: "https://example.com/login?next=/other")!

        #expect(!BrowserViewModel.sameTarget(base, withQuery))
        #expect(!BrowserViewModel.sameTarget(withQuery, otherQuery))
        #expect(BrowserViewModel.sameTarget(withQuery, withQuery))
        #expect(BrowserViewModel.sameTarget(base, base))
        // Scheme/host comparison is case-insensitive.
        #expect(BrowserViewModel.sameTarget(URL(string: "HTTPS://EXAMPLE.com/login")!, base))
        // Nil never matches.
        #expect(!BrowserViewModel.sameTarget(nil, base))
        #expect(!BrowserViewModel.sameTarget(base, nil))
        #expect(!BrowserViewModel.sameTarget(nil, nil))
    }

    // MARK: - resolveURL scheme allow-list

    @Test
    func resolveURL_neverReturnsNonWebSchemes() {
        // file:/data:/about:/javascript: inputs must never come back as
        // loadable URLs in those schemes — they either resolve to nil or to
        // an http(s) search/URL fallback.
        for input in [
            "file:///etc/passwd",
            "data:text/html,<h1>hi</h1>",
            "about:blank",
            "javascript:alert(1)",
        ] {
            let resolved = BrowserViewModel.resolveURL(from: input)
            if let scheme = resolved?.scheme?.lowercased() {
                #expect(scheme == "http" || scheme == "https", "input \(input) resolved to \(scheme)")
            }
        }
        // Legitimate inputs still work.
        #expect(BrowserViewModel.resolveURL(from: "example.com/login")?.absoluteString == "https://example.com/login")
        #expect(BrowserViewModel.resolveURL(from: "https://a.com/x?next=/y")?.absoluteString == "https://a.com/x?next=/y")
    }

    // MARK: - jsEscaped

    @Test
    func jsEscaped_escapesQuotesBackslashesAndNewlines() {
        #expect("plain".jsEscaped == "plain")
        #expect("it's".jsEscaped == "it\\'s")
        #expect("say \"hi\"".jsEscaped == "say \\\"hi\\\"")
        #expect("back\\slash".jsEscaped == "back\\\\slash")
        #expect("line\nbreak".jsEscaped == "line\\nbreak")
        #expect("carriage\rreturn".jsEscaped == "carriage\\rreturn")
    }

    @Test
    func jsEscaped_escapesUnicodeLineSeparators() {
        // U+2028/U+2029 are valid in JSON but are line terminators inside a
        // JS string literal — a password containing one would silently break
        // the whole injected script.
        #expect("a\u{2028}b".jsEscaped == "a\\u2028b")
        #expect("a\u{2029}b".jsEscaped == "a\\u2029b")
        let mixed = "x'\\y\u{2028}z\u{2029}"
        #expect(mixed.jsEscaped == "x\\'\\\\y\\u2028z\\u2029")
    }

    // MARK: - startRCR re-entrancy latch

    @MainActor
    private func makeViewModelWithVault() throws -> (BrowserViewModel, ModelContext) {
        let container = try ModelContainer(
            for: Credential.self,
                 SiteSetting.self,
                 BrowsingHistoryEntry.self,
                 Bookmark.self,
                 ExcludedDomain.self,
                 AttemptRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let vm = BrowserViewModel()
        vm.setup(modelContext: context)
        context.insert(Credential(domain: "example.com", username: "alice"))
        try context.save()
        vm.addNewTab(url: URL(string: "https://example.com/login")!)
        return (vm, context)
    }

    @Test @MainActor
    func startRCR_latchBlocksReentrantCall() async throws {
        let (vm, _) = try makeViewModelWithVault()

        vm.startRCR()
        // The latch is set synchronously, before the off-main preflight.
        #expect(vm.isStartingRCR)
        // A second tap inside the preflight window must be swallowed.
        vm.startRCR()
        #expect(vm.isStartingRCR)
        #expect(!vm.isRCRRunning)

        vm.stopRCR()
        #expect(!vm.isStartingRCR)
    }

    @Test @MainActor
    func startRCR_stopDuringPreflight_preventsStaleRunStart() async throws {
        let (vm, _) = try makeViewModelWithVault()

        vm.startRCR()
        #expect(vm.isStartingRCR)
        // Stop before the detached keychain preflight completes — its
        // continuation must see the cleared latch and never start the run.
        vm.stopRCR()

        try await Task.sleep(for: .milliseconds(400))
        #expect(!vm.isRCRRunning)
        #expect(vm.rcrTotal == 0)
    }

    // MARK: - Toast generation (newer toast survives older hide task)

    @Test @MainActor
    func showToast_newerToastSurvivesOlderHideTask() async throws {
        let vm = BrowserViewModel()

        vm.showToast("first", force: true)
        #expect(vm.toastVisible)
        #expect(vm.toastMessage == "first")

        // Replace the toast 1.2s in; the first toast's hide task fires at
        // 2.0s and must NOT hide the newer toast (which hides at 3.2s).
        try await Task.sleep(for: .milliseconds(1200))
        vm.showToast("second", force: true)

        try await Task.sleep(for: .milliseconds(1200)) // t=2.4s — old task fired
        #expect(vm.toastVisible)
        #expect(vm.toastMessage == "second")

        // The second toast's own hide task fires at t=3.2s.
        try await Task.sleep(for: .milliseconds(1300)) // t=3.7s
        #expect(!vm.toastVisible)
    }
}

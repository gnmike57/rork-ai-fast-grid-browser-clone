//
//  VaultSortTests.swift
//  FastBrowserv4Tests
//
//  Tests for VaultViewModel sort-ordering of credentials and for the
//  excluded-domain helpers that the vault relies on to hide entries.
//

import Testing
import Foundation
@testable import FastBrowserv4

struct VaultSortTests {

    @MainActor
    private func makeCredential(
        domain: String,
        username: String,
        usageCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdAt: Date = Date()
    ) -> Credential {
        let c = Credential(domain: domain, username: username)
        c.usageCount = usageCount
        c.lastUsedAt = lastUsedAt
        c.createdAt = createdAt
        return c
    }

    @Test @MainActor
    func sortByDomain_ordersByDomainThenUsername() {
        let creds = [
            makeCredential(domain: "b.com", username: "zack"),
            makeCredential(domain: "a.com", username: "bob"),
            makeCredential(domain: "a.com", username: "alice"),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .domain)
        #expect(sorted.map(\.username) == ["alice", "bob", "zack"])
    }

    @Test @MainActor
    func sortByRecentlyUsed_putsMostRecentFirstAndNilsLast() {
        let now = Date()
        let creds = [
            makeCredential(domain: "a.com", username: "never"),
            makeCredential(domain: "a.com", username: "old",    lastUsedAt: now.addingTimeInterval(-1000)),
            makeCredential(domain: "a.com", username: "recent", lastUsedAt: now),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .recentlyUsed)
        #expect(sorted.map(\.username) == ["recent", "old", "never"])
    }

    @Test @MainActor
    func sortByMostUsed_descendingUsageCount() {
        let creds = [
            makeCredential(domain: "a.com", username: "one",  usageCount: 1),
            makeCredential(domain: "a.com", username: "ten",  usageCount: 10),
            makeCredential(domain: "a.com", username: "five", usageCount: 5),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .mostUsed)
        #expect(sorted.map(\.username) == ["ten", "five", "one"])
    }

    @Test @MainActor
    func sortByRecentlyAdded_descendingCreatedAt() {
        let now = Date()
        let creds = [
            makeCredential(domain: "a.com", username: "oldest",   createdAt: now.addingTimeInterval(-2000)),
            makeCredential(domain: "a.com", username: "newest",   createdAt: now),
            makeCredential(domain: "a.com", username: "middle",   createdAt: now.addingTimeInterval(-1000)),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .recentlyAdded)
        #expect(sorted.map(\.username) == ["newest", "middle", "oldest"])
    }

    @Test @MainActor
    func excludedDomain_lowercasesOnInit() {
        let ex = ExcludedDomain(domain: "Example.COM")
        #expect(ex.domain == "example.com")
        #expect(ex.displayDomain == "example.com")
    }

    @Test @MainActor
    func excludedDomain_displayStripsWwwPrefix() {
        let ex = ExcludedDomain(domain: "www.example.com")
        #expect(ex.displayDomain == "example.com")
    }

    @Test @MainActor
    func excludedDomain_displayOnlyStripsLeadingWww() {
        // "awww.example.com" must NOT be mangled — only a leading "www." prefix is stripped.
        let ex = ExcludedDomain(domain: "awww.example.com")
        #expect(ex.displayDomain == "awww.example.com")
    }

    @Test @MainActor
    func credentialDisplayDomain_onlyStripsLeadingWww() {
        // Regression: `awww.example.com` must not become `a.example.com`.
        let bare = Credential(domain: "example.com", username: "u")
        #expect(bare.displayDomain == "example.com")

        let prefixed = Credential(domain: "www.example.com", username: "u")
        #expect(prefixed.displayDomain == "example.com")

        let tricky = Credential(domain: "awww.example.com", username: "u")
        #expect(tricky.displayDomain == "awww.example.com")
    }

    @Test @MainActor
    func excludedDomain_canonicalize_stripsSchemeAndPath() {
        #expect(ExcludedDomain.canonicalize("  HTTPS://Example.com/Login  ") == "example.com")
        #expect(ExcludedDomain.canonicalize("http://www.example.com") == "example.com")
        #expect(ExcludedDomain.canonicalize("example.com/path") == "example.com")
        #expect(ExcludedDomain.canonicalize("www.example.com") == "example.com")
        #expect(ExcludedDomain.canonicalize("awww.example.com") == "awww.example.com")
        #expect(ExcludedDomain.canonicalize("") == "")
        #expect(ExcludedDomain.canonicalize("   ") == "")
    }

    @Test @MainActor
    func excludedDomain_initCanonicalizesInput() {
        let ex = ExcludedDomain(domain: "https://WWW.Example.com/login")
        #expect(ex.domain == "example.com")
        #expect(ex.displayDomain == "example.com")
    }

    @Test @MainActor
    func sortByRecentlyUsed_tieBreaksOnDomainThenUsername() {
        // All three have `lastUsedAt == nil` so they should fall back to
        // domain-then-username, not just username.
        let creds = [
            makeCredential(domain: "b.com", username: "alice"),
            makeCredential(domain: "a.com", username: "bob"),
            makeCredential(domain: "a.com", username: "alice"),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .recentlyUsed)
        #expect(sorted.map { "\($0.domain)/\($0.username)" } == [
            "a.com/alice", "a.com/bob", "b.com/alice",
        ])
    }

    @Test @MainActor
    func sortByMostUsed_tieBreaksOnDomainThenUsername() {
        let creds = [
            makeCredential(domain: "b.com", username: "alice", usageCount: 5),
            makeCredential(domain: "a.com", username: "bob",   usageCount: 5),
            makeCredential(domain: "a.com", username: "alice", usageCount: 5),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .mostUsed)
        #expect(sorted.map { "\($0.domain)/\($0.username)" } == [
            "a.com/alice", "a.com/bob", "b.com/alice",
        ])
    }

    @Test @MainActor
    func sortByRecentlyAdded_tieBreaksOnDomainThenUsername() {
        let sharedDate = Date()
        let creds = [
            makeCredential(domain: "b.com", username: "alice", createdAt: sharedDate),
            makeCredential(domain: "a.com", username: "bob",   createdAt: sharedDate),
            makeCredential(domain: "a.com", username: "alice", createdAt: sharedDate),
        ]
        let sorted = VaultViewModel.sortCredentials(creds, by: .recentlyAdded)
        #expect(sorted.map { "\($0.domain)/\($0.username)" } == [
            "a.com/alice", "a.com/bob", "b.com/alice",
        ])
    }

    // MARK: - Domain normalization parity

    @Test @MainActor
    func extractDomain_onlyStripsLeadingWww() {
        // Parity with `ExcludedDomain.canonicalize` and `BrowserTab.domain`:
        // only a *leading* `www.` is stripped.
        #expect(CredentialImportService.extractDomain(from: "https://www.example.com/login") == "example.com")
        #expect(CredentialImportService.extractDomain(from: "example.com") == "example.com")
        #expect(CredentialImportService.extractDomain(from: "awww.example.com") == "awww.example.com")
        #expect(CredentialImportService.extractDomain(from: "HTTPS://Example.COM") == "example.com")
    }

    @Test @MainActor
    func browserTab_domain_onlyStripsLeadingWww() {
        let prefixed = BrowserTab(url: URL(string: "https://www.example.com/login")!)
        #expect(prefixed.domain == "example.com")

        let tricky = BrowserTab(url: URL(string: "https://awww.example.com/login")!)
        #expect(tricky.domain == "awww.example.com")

        let bare = BrowserTab(url: URL(string: "https://example.com")!)
        #expect(bare.domain == "example.com")
    }

    // MARK: - Bulk delete / move-to-exclude result contracts

    @Test @MainActor
    func bulkMoveResult_defaultFieldsAreIndependent() {
        // Keep the BulkMoveResult contract pinned so the callers in
        // VaultView can rely on both fields being populated.
        let r = VaultViewModel.BulkMoveResult(domainsAdded: 3, failedCredentialIDs: ["x"])
        #expect(r.domainsAdded == 3)
        #expect(r.failedCredentialIDs == ["x"])
    }
}

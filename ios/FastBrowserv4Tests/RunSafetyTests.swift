//
//  RunSafetyTests.swift
//  FastBrowserv4Tests
//
//  Coverage for the riskiest run logic: the balanced queue partition every
//  RCR run splits the vault with, the finished-credential detection that
//  decides what a resumed run skips, and the Needs Review quarantine flow
//  that replaced immediate deletion on a "disabled" signal. These are
//  exactly the paths that would silently reintroduce data loss if a future
//  change broke them.
//
//  NOTE: every boolean handed to #expect below is precomputed into a local
//  `let` first. The swift-testing macro can fail to type-check a `rethrows`
//  call (allSatisfy/contains/filter with a closure or key path) when it's
//  written inline inside #expect(...) — precomputing sidesteps that.
//

import Testing
import Foundation
import SwiftData
@testable import FastBrowserv4

struct RunSafetyTests {

    // MARK: - Queue partitioning (QuadController.roundRobinSlices)

    @Test
    func roundRobinSlices_splitsEvenlyToWithinOne() {
        let slices = QuadController.roundRobinSlices(Array(0..<10), windowCount: 4)
        #expect(slices.count == 4)
        let counts = slices.map { $0.count }.sorted()
        // 10 items over 4 windows: two windows get 3, two get 2 — never off
        // by more than one, and nothing is dropped or duplicated.
        #expect(counts == [2, 2, 3, 3])
        let flattenedSorted = slices.flatMap { $0 }.sorted()
        #expect(flattenedSorted == Array(0..<10))
    }

    @Test
    func roundRobinSlices_moreWindowsThanItemsLeavesSomeEmptyNeverCrashes() {
        let slices = QuadController.roundRobinSlices(["a", "b"], windowCount: 5)
        #expect(slices.count == 5)
        let flattened = slices.flatMap { $0 }
        #expect(flattened == ["a", "b"])
        let emptyCount = slices.filter { $0.isEmpty }.count
        #expect(emptyCount == 3)
    }

    @Test
    func roundRobinSlices_emptyQueueProducesEmptySlicesNotCrash() {
        let slices = QuadController.roundRobinSlices([Int](), windowCount: 4)
        #expect(slices.count == 4)
        let allEmpty = slices.allSatisfy { $0.isEmpty }
        #expect(allEmpty)
    }

    @Test
    func roundRobinSlices_zeroWindowsReturnsEmpty() {
        let slices = QuadController.roundRobinSlices([1, 2, 3], windowCount: 0)
        #expect(slices.isEmpty)
    }

    // MARK: - Finished-credential detection (AttemptTrackingService)

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Credential.self,
                 SiteSetting.self,
                 BrowsingHistoryEntry.self,
                 Bookmark.self,
                 ExcludedDomain.self,
                 AttemptRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return container.mainContext
    }

    @Test @MainActor
    func credentialIsFinished_falseWithNoAttempts() throws {
        let context = try makeContext()
        let finished = AttemptTrackingService.shared.credentialIsFinished(
            context: context, credentialID: "cred-1", targetDomain: "example.com", totalPasswords: 3
        )
        #expect(!finished)
    }

    @Test @MainActor
    func credentialIsFinished_trueOnAnySuccess() throws {
        let context = try makeContext()
        _ = AttemptTrackingService.shared.recordAttempt(
            context: context, credentialID: "cred-1", username: "alice", password: "pw1",
            passwordIndex: 1, passwordTotal: 3, targetDomain: "example.com", sessionTag: "single",
            status: .success
        )
        let finished = AttemptTrackingService.shared.credentialIsFinished(
            context: context, credentialID: "cred-1", targetDomain: "example.com", totalPasswords: 3
        )
        #expect(finished, "A single success must finish the credential even with untried passwords left")
    }

    @Test @MainActor
    func credentialIsFinished_falseUntilEveryPasswordIsExhausted() throws {
        let context = try makeContext()
        for i in 1...2 {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context, credentialID: "cred-1", username: "alice", password: "pw\(i)",
                passwordIndex: i, passwordTotal: 3, targetDomain: "example.com", sessionTag: "single",
                status: .failed
            )
        }
        let finishedEarly = AttemptTrackingService.shared.credentialIsFinished(
            context: context, credentialID: "cred-1", targetDomain: "example.com", totalPasswords: 3
        )
        #expect(!finishedEarly, "2 of 3 passwords failed — the 3rd hasn't been tried, so the credential must stay in the queue")

        _ = AttemptTrackingService.shared.recordAttempt(
            context: context, credentialID: "cred-1", username: "alice", password: "pw3",
            passwordIndex: 3, passwordTotal: 3, targetDomain: "example.com", sessionTag: "single",
            status: .disabled
        )
        let finishedAfterAll = AttemptTrackingService.shared.credentialIsFinished(
            context: context, credentialID: "cred-1", targetDomain: "example.com", totalPasswords: 3
        )
        #expect(finishedAfterAll, "All 3 passwords now have a terminal result")
    }

    @Test @MainActor
    func credentialIsFinished_isScopedPerTargetDomain() throws {
        let context = try makeContext()
        _ = AttemptTrackingService.shared.recordAttempt(
            context: context, credentialID: "cred-1", username: "alice", password: "pw1",
            passwordIndex: 1, passwordTotal: 1, targetDomain: "siteA.com", sessionTag: "single",
            status: .success
        )
        let finishedOnOtherSite = AttemptTrackingService.shared.credentialIsFinished(
            context: context, credentialID: "cred-1", targetDomain: "siteB.com", totalPasswords: 1
        )
        #expect(!finishedOnOtherSite, "A success against siteA must not finish the same credential against siteB")
    }

    // MARK: - Needs Review quarantine (replaces immediate deletion)

    @MainActor
    private func makeCredentialContext() throws -> (ModelContext, Credential) {
        let container = try ModelContainer(
            for: Credential.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let credential = Credential(domain: "example.com", username: "alice")
        context.insert(credential)
        try context.save()
        return (context, credential)
    }

    @Test @MainActor
    func needsReviewStore_flagHoldsTheCredentialInsteadOfDeletingIt() throws {
        let store = NeedsReviewStore.shared
        let (context, credential) = try makeCredentialContext()
        defer { store.remove(credentialID: credential.id) }

        store.flag(credentialID: credential.id, username: credential.username, domain: credential.domain, reason: "test")

        let isFlagged = store.entries.contains { $0.id == credential.id }
        #expect(isFlagged)
        // Nothing was deleted — the row and its context are untouched.
        let allCredentials = try context.fetch(FetchDescriptor<Credential>())
        let stillThere = allCredentials.contains { $0.id == credential.id }
        #expect(stillThere, "Flagging must never delete the credential")
    }

    @Test @MainActor
    func needsReviewStore_flagIsIdempotentPerCredential() throws {
        let store = NeedsReviewStore.shared
        let (_, credential) = try makeCredentialContext()
        defer { store.remove(credentialID: credential.id) }

        store.flag(credentialID: credential.id, username: credential.username, domain: credential.domain, reason: "first")
        store.flag(credentialID: credential.id, username: credential.username, domain: credential.domain, reason: "second")

        let matchingCount = store.entries.filter { $0.id == credential.id }.count
        #expect(matchingCount == 1)
    }

    @Test @MainActor
    func needsReviewStore_keepRemovesTheFlagAndUnblocksFutureRuns() throws {
        let store = NeedsReviewStore.shared
        let (_, credential) = try makeCredentialContext()
        defer {
            store.remove(credentialID: credential.id)
            PermaDisabledStore.shared.clear(credentialID: credential.id)
        }

        store.flag(credentialID: credential.id, username: credential.username, domain: credential.domain, reason: "test")
        PermaDisabledStore.shared.markDisabled(credentialID: credential.id)

        store.keep(credentialID: credential.id)

        let stillFlagged = store.entries.contains { $0.id == credential.id }
        #expect(!stillFlagged)
        let stillBlocked = PermaDisabledStore.shared.isDisabled(credentialID: credential.id)
        #expect(!stillBlocked, "Keep must let a future run try the account again")
    }

    @Test @MainActor
    func needsReviewStore_confirmDeleteActuallyRemovesTheCredential() throws {
        let store = NeedsReviewStore.shared
        let (context, credential) = try makeCredentialContext()
        store.flag(credentialID: credential.id, username: credential.username, domain: credential.domain, reason: "test")

        store.confirmDelete(credential, context: context)

        let stillFlagged = store.entries.contains { $0.id == credential.id }
        #expect(!stillFlagged)
        let allCredentials = try context.fetch(FetchDescriptor<Credential>())
        let stillThere = allCredentials.contains { $0.id == credential.id }
        #expect(!stillThere, "An explicit confirm must actually remove the row")
    }

    @Test @MainActor
    func needsReviewStore_markRunStartedScopesTheSummaryToTheNewRun() throws {
        let store = NeedsReviewStore.shared
        let (_, credential) = try makeCredentialContext()
        defer { store.remove(credentialID: credential.id) }

        store.flag(credentialID: credential.id, username: credential.username, domain: credential.domain, reason: "old run")
        #expect(store.hasFlaggedThisRun)

        store.markRunStarted()
        #expect(!store.hasFlaggedThisRun, "A new run must start with an empty this-run bucket")
        // The persisted entry itself must survive — only the "this run" set resets.
        let stillPersisted = store.entries.contains { $0.id == credential.id }
        #expect(stillPersisted)
    }
}

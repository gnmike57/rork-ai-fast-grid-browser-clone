//
//  AuditFixTests.swift
//  FastBrowserv4Tests
//
//  Regression tests for the full-audit fixes: focus moving off disabled
//  cells, all-lane progress sums, resume counter backfill, and duplicate
//  import password merging.
//

import Testing
import Foundation
@testable import FastBrowserv4

struct AuditFixTests {

    // MARK: - Focus moves off unused tiles

    @Test @MainActor
    func refocusMovesOffDisabledCenterInThreeByThreeDualSite() {
        let controller = QuadController()
        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!

        controller.setGridSize(.nine)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)

        // Simulate the user having tapped the center tile before switching
        // into dual-site mode.
        controller.focusedIndex = 4
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)

        #expect(controller.focusedIndex != 4, "Focus must move off the disabled center")
        #expect(!controller.focusedSession.isDisabled, "Focused session must be enabled")
        #expect(controller.focusedIndex < controller.activeCount)
    }

    @Test @MainActor
    func refocusKeepsValidFocus() {
        let controller = QuadController()
        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!

        controller.setGridSize(.four)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .horizontal)
        controller.focusedIndex = 1
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .horizontal)

        #expect(controller.focusedIndex == 1, "A valid focus must not move")
    }

    // MARK: - Compact-bar progress sums all lanes

    @Test
    func overallProgressSumsAllLanes() {
        // Regression: the compact bar used only the first lane's numbers.
        let result = QuadController.overallProgress(
            completedPerLane: [3, 2, 1, 1],
            totalsPerLane: [5, 2, 3, 0]
        )
        #expect(result.completed == 7)
        #expect(result.total == 10)
    }

    @Test
    func overallProgressHandlesEmptyLanes() {
        let result = QuadController.overallProgress(
            completedPerLane: [],
            totalsPerLane: []
        )
        #expect(result.completed == 0)
        #expect(result.total == 0)
    }

    // MARK: - Resume counter backfill

    @Test
    func laneBackfillCountsOnlyFinishedBothCredentials() {
        let slices = [["a", "b", "c"], ["d", "e"]]
        let counts = QuadController.laneBackfillCounts(
            slices: slices,
            finishedIDs: ["a", "c", "d"]
        )
        #expect(counts == [2, 1])
    }

    @Test
    func laneBackfillCountsZeroWhenNothingFinished() {
        let slices = [["a", "b"], ["c"]]
        let counts = QuadController.laneBackfillCounts(
            slices: slices,
            finishedIDs: []
        )
        #expect(counts == [0, 0])
    }

    // MARK: - Duplicate import merging

    @Test
    func passwordMergeDeduplicatesAndPreservesOrder() {
        let merged = CredentialImportService.mergePasswords(
            existing: ["one", "two"],
            new: ["two", "three", "one"]
        )
        #expect(merged == ["one", "two", "three"])
    }

    @Test
    func passwordMergeKeepsExistingWhenNothingNew() {
        let merged = CredentialImportService.mergePasswords(
            existing: ["one", "two"],
            new: []
        )
        #expect(merged == ["one", "two"])
    }

    // MARK: - Password generator robustness

    @Test @MainActor
    func passwordGeneratorProducesRequestedLength() {
        let long = PasswordGeneratorService.generate(length: 20)
        #expect(long.count == 20)
        let short = PasswordGeneratorService.generate(length: 8)
        #expect(short.count == 8)
    }

    @Test @MainActor
    func passwordGeneratorEmptyCharacterSetReturnsEmpty() {
        let password = PasswordGeneratorService.generate(
            length: 12,
            includeUppercase: false,
            includeLowercase: false,
            includeNumbers: false,
            includeSymbols: false
        )
        #expect(password.isEmpty)
    }
}

//
//  FollowLeaderUnbreakableTests.swift
//  FastBrowserv4Tests
//
//  The rules that make Unbreakable mode mean what it says: a queue that never
//  merges, a repair that splices instead of clearing, the settlement rule that
//  keeps a quiet button from being pressed twice, what counts as a point of no
//  return, and the ledger's bookkeeping — including its promise never to carry
//  a typed value onto a screen.
//

import Testing
import Foundation
@testable import FastBrowserv4

struct FollowLeaderUnbreakableTests {

    // MARK: - Helpers

    private func hint(
        id: String = "",
        name: String = "",
        tag: String = "input",
        type: String = "",
        label: String = ""
    ) -> FollowLeaderHint {
        var h = FollowLeaderHint()
        h.id = id
        h.name = name
        h.tag = tag
        h.type = type
        h.label = label
        return h
    }

    private func typing(_ value: String, name: String = "user", seq: Int) -> FollowLeaderAction {
        FollowLeaderAction(
            seq: seq,
            kind: .input,
            selector: "form > input:nth-of-type(1)",
            value: value,
            hint: hint(name: name)
        )
    }

    // MARK: - The queue never merges in strict mode

    @Test func strictQueueKeepsEveryKeystroke() {
        var queue = FollowLeaderQueue(isStrict: true)
        queue.enqueue(typing("4", seq: 1))
        queue.enqueue(typing("42", seq: 2))
        queue.enqueue(typing("424", seq: 3))

        // An input mask only behaves the same way if it sees the same states.
        #expect(queue.count == 3)
        #expect(queue.dequeue()?.value == "4")
        #expect(queue.dequeue()?.value == "42")
        #expect(queue.dequeue()?.value == "424")
    }

    @Test func strictQueueKeepsEveryScrollPosition() {
        var queue = FollowLeaderQueue(isStrict: true)
        for (index, y) in [120, 240, 360].enumerated() {
            queue.enqueue(FollowLeaderAction(seq: index + 1, kind: .scroll, scrollY: y))
        }
        #expect(queue.count == 3)
    }

    @Test func relaxedQueueStillMergesExactlyAsItDid() {
        var queue = FollowLeaderQueue()
        queue.enqueue(typing("4", seq: 1))
        queue.enqueue(typing("42", seq: 2))
        #expect(queue.count == 1)
        #expect(queue.dequeue()?.value == "42")
    }

    @Test func enqueueReportsWhetherItMerged() {
        var strict = FollowLeaderQueue(isStrict: true)
        strict.enqueue(typing("a", seq: 1))
        #expect(strict.enqueue(typing("ab", seq: 2)) == false)

        var relaxed = FollowLeaderQueue()
        relaxed.enqueue(typing("a", seq: 1))
        #expect(relaxed.enqueue(typing("ab", seq: 2)) == true)
    }

    @Test func strictQueueStillNeverReordersTypingPastItsSubmit() {
        var queue = FollowLeaderQueue(isStrict: true)
        queue.enqueue(typing("john", seq: 1))
        queue.enqueue(FollowLeaderAction(seq: 2, kind: .submit, selector: "form"))
        queue.enqueue(typing("johnny", seq: 3))

        #expect(queue.dequeue()?.kind == .input)
        #expect(queue.dequeue()?.kind == .submit)
        #expect(queue.dequeue()?.kind == .input)
    }

    // MARK: - Repair splices rather than clears

    @Test func repairReplaysThePageAndKeepsWhatArrivedDuringIt() {
        var queue = FollowLeaderQueue(isStrict: true)
        // Typed while the window was reloading — these must survive.
        queue.enqueue(typing("later", seq: 9))
        queue.enqueue(typing("later still", seq: 10))

        let journal = [
            typing("j", seq: 1),
            typing("jo", seq: 2),
            FollowLeaderAction(seq: 3, kind: .click, selector: "button")
        ]
        queue.replaceWithRepair(journal: journal)

        #expect(queue.count == 5)
        #expect(queue.dequeue()?.seq == 1)
        #expect(queue.dequeue()?.seq == 2)
        #expect(queue.dequeue()?.seq == 3)
        #expect(queue.dequeue()?.seq == 9)
        #expect(queue.dequeue()?.seq == 10)
    }

    @Test func repairDropsTheStaleCopiesOfJournalledActions() {
        var queue = FollowLeaderQueue(isStrict: true)
        // The window was mid-backlog: these are the same actions the journal
        // already holds, so replaying both would apply them twice.
        queue.enqueue(typing("jo", seq: 2))
        queue.enqueue(FollowLeaderAction(seq: 3, kind: .click, selector: "button"))

        queue.replaceWithRepair(journal: [typing("j", seq: 1), typing("jo", seq: 2), FollowLeaderAction(seq: 3, kind: .click)])

        #expect(queue.count == 3)
        #expect(queue.newestSeq == 3)
    }

    @Test func repairIntoAnEmptyQueueIsJustTheJournal() {
        var queue = FollowLeaderQueue(isStrict: true)
        queue.replaceWithRepair(journal: [typing("a", seq: 1), typing("ab", seq: 2)])
        #expect(queue.count == 2)
    }

    // MARK: - Settlement

    @Test func onlyAGenuineMissIsAllowedToRetry() {
        let confirmed = FollowLeaderSettlement(
            outcome: FollowLeaderApplyOutcome(ok: true, verified: true, method: "nativeClick")
        )
        let delivered = FollowLeaderSettlement(
            outcome: FollowLeaderApplyOutcome(ok: true, verified: false, method: "delivered")
        )
        let missed = FollowLeaderSettlement(outcome: .failure(reason: "not-found"))

        #expect(confirmed == .confirmed)
        #expect(delivered == .delivered)
        #expect(missed == .missed)

        // A provably delivered tap is finished. Retrying it is how a quiet
        // submit button gets pressed a second time.
        #expect(confirmed.isSettled)
        #expect(delivered.isSettled)
        #expect(missed.isSettled == false)
    }

    @Test func anUnreadableResultCountsAsAMissRatherThanASuccess() {
        let settlement = FollowLeaderSettlement(outcome: FollowLeaderApplyOutcome(jsResult: "nonsense"))
        #expect(settlement == .missed)
    }

    // MARK: - Points of no return

    @Test func submitsEntersAndSubmitButtonsAreCommitPoints() {
        #expect(FollowLeaderCommitPoint.isCommit(FollowLeaderAction(seq: 1, kind: .submit)))
        #expect(FollowLeaderCommitPoint.isCommit(FollowLeaderAction(seq: 2, kind: .key, key: "Enter")))
        #expect(FollowLeaderCommitPoint.isCommit(
            FollowLeaderAction(seq: 3, kind: .click, hint: hint(tag: "button", type: "submit"))
        ))
    }

    @Test func ordinaryTypingAndBrowsingIsNotACommitPoint() {
        #expect(FollowLeaderCommitPoint.isCommit(typing("john", seq: 1)) == false)
        #expect(FollowLeaderCommitPoint.isCommit(FollowLeaderAction(seq: 2, kind: .scroll)) == false)
        #expect(FollowLeaderCommitPoint.isCommit(FollowLeaderAction(seq: 3, kind: .hover)) == false)
        #expect(FollowLeaderCommitPoint.isCommit(FollowLeaderAction(seq: 4, kind: .focus)) == false)
        // Every other key travels freely — only Enter commits.
        #expect(FollowLeaderCommitPoint.isCommit(FollowLeaderAction(seq: 5, kind: .key, key: "Backspace")) == false)
    }

    @Test func theRecordersOwnVerdictIsHonoured() {
        // The page can see things the hint cannot — a button inside a form, or
        // one that says "Place order" — so its answer wins.
        let action = FollowLeaderAction(seq: 1, kind: .click, isCommit: true, hint: hint(tag: "div"))
        #expect(FollowLeaderCommitPoint.isCommit(action))
    }

    // MARK: - Payload parsing

    @Test func parsesModifiersTapPointAndCommitFlag() {
        let action = FollowLeaderAction(
            payload: [
                "kind": "click",
                "mods": "meta+shift",
                "px": 0.72,
                "py": 0.4,
                "commit": true,
                "hint": ["tag": "BUTTON"]
            ],
            seq: 7
        )
        #expect(action?.modifiers == "meta+shift")
        #expect(action?.pointX == 0.72)
        #expect(action?.pointY == 0.4)
        #expect(action?.isCommit == true)
    }

    @Test func aMissingTapPointMeansCentreNotCorner() {
        let action = FollowLeaderAction(payload: ["kind": "click"], seq: 1)
        // Negative is the sentinel the replay engine reads as "no point
        // recorded"; zero would aim at the top-left corner of the control.
        #expect((action?.pointX ?? 0) < 0)
        #expect((action?.pointY ?? 0) < 0)
    }

    @Test func anOutOfRangeTapPointIsClampedIntoTheElement() {
        let action = FollowLeaderAction(payload: ["kind": "click", "px": 1.8, "py": 0.5], seq: 1)
        #expect(action?.pointX == 1)
    }

    @Test func theNewKindsRoundTripThroughTheRecorderPayload() {
        for kind in ["focus", "blur", "hover"] {
            let action = FollowLeaderAction(payload: ["kind": kind], seq: 1)
            #expect(action?.kind.rawValue == kind)
        }
    }

    @Test func everyFieldTheReplayEngineReadsIsHandedToIt() {
        let action = FollowLeaderAction(
            seq: 1,
            kind: .click,
            modifiers: "shift",
            pointX: 0.5,
            pointY: 0.25
        )
        let args = action.jsArguments
        #expect(args["mods"] as? String == "shift")
        #expect(args["px"] as? Double == 0.5)
        #expect(args["py"] as? Double == 0.25)
    }

    // MARK: - The ledger never carries a value

    @Test func theLedgerDescribesTypingWithoutRepeatingIt() {
        let action = FollowLeaderAction(
            seq: 1,
            kind: .input,
            value: "4242424242424242",
            hint: hint(name: "cardnumber", tag: "input", label: "Card number")
        )
        let summary = action.ledgerSummary
        #expect(summary == "Typed into Card number")
        #expect(summary.contains("4242") == false)
    }

    @Test func aChosenOptionIsNamedButNeverQuoted() {
        let action = FollowLeaderAction(
            seq: 1,
            kind: .select,
            value: "sensitive-option-value",
            hint: hint(name: "country", tag: "select", label: "Country")
        )
        #expect(action.ledgerSummary.contains("sensitive-option-value") == false)
        #expect(action.ledgerSummary == "Chose an option in Country")
    }

    @Test func summariesReadLikeSentencesForEveryKind() {
        #expect(FollowLeaderAction(seq: 1, kind: .submit).ledgerSummary == "Submitted the form")
        #expect(FollowLeaderAction(seq: 2, kind: .scroll).ledgerSummary == "Scrolled")
        #expect(FollowLeaderAction(seq: 3, kind: .key, key: "Enter").ledgerSummary == "Pressed Enter")
        #expect(
            FollowLeaderAction(seq: 4, kind: .key, key: "a", modifiers: "meta").ledgerSummary
                == "Pressed meta+a"
        )
        #expect(
            FollowLeaderAction(seq: 5, kind: .click, hint: hint(tag: "button", label: "Place order"))
                .ledgerSummary == "Tapped Place order"
        )
    }

    @Test func anElementIsNamedTheWayAPersonWouldNameIt() {
        var h = FollowLeaderHint()
        h.tag = "input"
        h.id = "ctl00_txtCard"
        h.name = "cardnum"
        h.label = "Card number"
        // The label beats the machine identifiers.
        #expect(h.describedName == "Card number")

        var bare = FollowLeaderHint()
        bare.tag = "button"
        #expect(bare.describedName == "button")
    }

    // MARK: - Ledger bookkeeping

    @Test func aRowTracksEveryWindowUntilTheyAllSettle() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 1, kind: .input, summary: "Typed into Email", isCommit: false, windows: [1, 2, 3])

        #expect(ledger.entries.first?.pendingCount == 3)
        #expect(ledger.waitingCount == 1)

        ledger.mark(seq: 1, window: 1, state: .confirmed)
        ledger.mark(seq: 1, window: 2, state: .delivered)
        #expect(ledger.entries.first?.pendingCount == 1)
        #expect(ledger.waitingCount == 1)

        ledger.mark(seq: 1, window: 3, state: .confirmed)
        #expect(ledger.entries.first?.isWaiting == false)
        #expect(ledger.waitingCount == 0)
    }

    @Test func aRepairStaysOnTheRecordEvenAfterItSucceeds() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 1, kind: .click, summary: "Tapped Continue", isCommit: true, windows: [1])
        ledger.mark(seq: 1, window: 1, state: .repaired)
        // The replay that follows a repair confirms the action, but the row
        // must still say the window had to be rebuilt to get there.
        ledger.mark(seq: 1, window: 1, state: .confirmed)

        #expect(ledger.entries.first?.states[1] == .repaired)
        #expect(ledger.repairedCount == 1)
    }

    @Test func aDroppedWindowGreysOutAndStaysThatWay() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 1, kind: .input, summary: "Typed into Email", isCommit: false, windows: [1, 2])
        ledger.mark(seq: 1, window: 1, state: .confirmed)
        ledger.record(seq: 2, kind: .click, summary: "Tapped Sign in", isCommit: true, windows: [1, 2])

        ledger.markDropped(window: 2)

        // Settled history is preserved; only what it never did becomes a drop.
        #expect(ledger.entries[0].states[1] == .confirmed)
        #expect(ledger.entries[0].states[2] == .dropped)
        #expect(ledger.entries[1].states[2] == .dropped)

        // And nothing can quietly resurrect it.
        ledger.mark(seq: 2, window: 2, state: .confirmed)
        #expect(ledger.entries[1].states[2] == .dropped)
    }

    @Test func theSameActionIsNeverRecordedTwice() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 5, kind: .input, summary: "Typed", isCommit: false, windows: [1])
        ledger.record(seq: 5, kind: .input, summary: "Typed", isCommit: false, windows: [1])
        #expect(ledger.count == 1)
    }

    @Test func theLedgerStaysBoundedAndKeepsTheNewestRowsAddressable() {
        var ledger = FollowLeaderLedger()
        let overflow = FollowLeaderLedger.capacity + 40
        for seq in 1...overflow {
            ledger.record(seq: seq, kind: .scroll, summary: "Scrolled", isCommit: false, windows: [1])
        }
        #expect(ledger.count == FollowLeaderLedger.capacity)
        #expect(ledger.entries.last?.id == overflow)

        // Trimming rebuilds the lookup, so the surviving rows are still
        // reachable by sequence number rather than silently unmarkable.
        ledger.mark(seq: overflow, window: 1, state: .confirmed)
        #expect(ledger.entries.last?.states[1] == .confirmed)
    }

    @Test func windowCellsAlwaysDrawInTheSameOrder() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 1, kind: .input, summary: "Typed", isCommit: false, windows: [7, 2, 4])
        #expect(ledger.entries.first?.windowOrder == [2, 4, 7])
    }

    @Test func clearingTheLedgerAlsoClearsItsLookup() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 1, kind: .input, summary: "Typed", isCommit: false, windows: [1])
        ledger.removeAll()
        #expect(ledger.isEmpty)

        // A recycled sequence number must be recordable again.
        ledger.record(seq: 1, kind: .click, summary: "Tapped", isCommit: false, windows: [1])
        #expect(ledger.count == 1)
    }

    // MARK: - Filters

    @Test func filtersSelectTheRowsTheyName() {
        var ledger = FollowLeaderLedger()
        ledger.record(seq: 1, kind: .input, summary: "Typed", isCommit: false, windows: [1, 2])
        ledger.mark(seq: 1, window: 1, state: .confirmed)
        ledger.mark(seq: 1, window: 2, state: .repaired)
        ledger.record(seq: 2, kind: .click, summary: "Tapped", isCommit: false, windows: [1, 2])
        ledger.mark(seq: 2, window: 1, state: .confirmed)
        ledger.mark(seq: 2, window: 2, state: .confirmed)

        let repaired = ledger.entries.filter { FollowLeaderLedgerFilter.repaired.matches($0) }
        let waiting = ledger.entries.filter { FollowLeaderLedgerFilter.waiting.matches($0) }
        let all = ledger.entries.filter { FollowLeaderLedgerFilter.all.matches($0) }

        #expect(repaired.count == 1)
        #expect(repaired.first?.id == 1)
        #expect(waiting.isEmpty)
        #expect(all.count == 2)
    }

    // MARK: - The mode itself

    @Test func relaxedIsTheDefaultAndOnlyUnbreakableIsStrict() {
        #expect(FollowLeaderSyncMode.relaxed.isStrict == false)
        #expect(FollowLeaderSyncMode.unbreakable.isStrict)
        #expect(FollowLeaderSyncMode(rawValue: "nonsense") == nil)
        #expect(FollowLeaderSyncMode.allCases.count == 2)
    }

    @Test func bothModesExplainThemselves() {
        for mode in FollowLeaderSyncMode.allCases {
            #expect(mode.label.isEmpty == false)
            #expect(mode.blurb.isEmpty == false)
            #expect(mode.iconName.isEmpty == false)
        }
    }

    // MARK: - Strict pacing is a safety ceiling, never a shortcut

    @Test func theCommitHoldNeverShrinksBelowItsBase() {
        let base = SpeedProfile.normal.followLeaderGateTimeout.seconds
        for profile in SpeedProfile.allCases {
            // Turbo may not shorten the window a follower has to catch up in,
            // or the dial would quietly turn exactness back off.
            #expect(profile.followLeaderGateTimeout.seconds >= base)
        }
        #expect(SpeedProfile.slow.followLeaderGateTimeout.seconds > base)
    }

    @Test func aRepairIsGivenLongerThanASingleAction() {
        for profile in SpeedProfile.allCases {
            #expect(profile.followLeaderRepairTimeout.seconds > profile.followLeaderActionTimeout.seconds)
            #expect(profile.followLeaderRepairSettle.seconds > 0)
        }
    }

    @Test func theDialStillOrdersTheRepairSettle() {
        #expect(SpeedProfile.slow.followLeaderRepairSettle.seconds > SpeedProfile.normal.followLeaderRepairSettle.seconds)
        #expect(SpeedProfile.normal.followLeaderRepairSettle.seconds > SpeedProfile.turbo.followLeaderRepairSettle.seconds)
    }
}

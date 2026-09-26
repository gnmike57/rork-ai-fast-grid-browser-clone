//
//  FollowLeaderMirrorTests.swift
//  FastBrowserv4Tests
//
//  The ordering / coalescing rules of the per-follower mirroring queue, the
//  drift-resync decision, action parsing, and the mirroring pace of the speed
//  dial. These are the pieces a wrong answer in silently corrupts a live
//  login — order especially, since typing must never land after its submit.
//

import Testing
import Foundation
@testable import FastBrowserv4

struct FollowLeaderMirrorTests {

    // MARK: - Helpers

    private func hint(id: String = "", name: String = "", tag: String = "input") -> FollowLeaderHint {
        var h = FollowLeaderHint()
        h.id = id
        h.name = name
        h.tag = tag
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

    // MARK: - Queue ordering

    @Test func consecutiveTypingCollapsesToTheFinalValue() {
        var queue = FollowLeaderQueue()
        queue.enqueue(typing("j", seq: 1))
        queue.enqueue(typing("jo", seq: 2))
        queue.enqueue(typing("john", seq: 3))

        #expect(queue.count == 1)
        let action = queue.dequeue()
        #expect(action?.value == "john")
        #expect(queue.isEmpty)
    }

    @Test func typingAfterAClickDoesNotJumpAheadOfIt() {
        var queue = FollowLeaderQueue()
        queue.enqueue(typing("john", seq: 1))
        queue.enqueue(FollowLeaderAction(seq: 2, kind: .click, selector: "button"))
        queue.enqueue(typing("johnny", seq: 3))

        // Three distinct steps: merging the second edit back into the first
        // would replay it before the click that already happened.
        #expect(queue.count == 3)
        #expect(queue.dequeue()?.kind == .input)
        #expect(queue.dequeue()?.kind == .click)
        let tail = queue.dequeue()
        #expect(tail?.kind == .input)
        #expect(tail?.value == "johnny")
    }

    @Test func differentFieldsNeverCollapseIntoEachOther() {
        var queue = FollowLeaderQueue()
        queue.enqueue(typing("john", name: "user", seq: 1))
        queue.enqueue(typing("hunter2", name: "pass", seq: 2))

        #expect(queue.count == 2)
        #expect(queue.dequeue()?.value == "john")
        #expect(queue.dequeue()?.value == "hunter2")
    }

    @Test func consecutiveScrollsCollapseToTheLatestPosition() {
        var queue = FollowLeaderQueue()
        queue.enqueue(FollowLeaderAction(seq: 1, kind: .scroll, scrollY: 100))
        queue.enqueue(FollowLeaderAction(seq: 2, kind: .scroll, scrollY: 400))
        queue.enqueue(FollowLeaderAction(seq: 3, kind: .scroll, scrollY: 900))

        #expect(queue.count == 1)
        #expect(queue.dequeue()?.scrollY == 900)
    }

    @Test func clicksAndSubmitsAreNeverCollapsed() {
        var queue = FollowLeaderQueue()
        queue.enqueue(FollowLeaderAction(seq: 1, kind: .click, selector: "button"))
        queue.enqueue(FollowLeaderAction(seq: 2, kind: .click, selector: "button"))
        queue.enqueue(FollowLeaderAction(seq: 3, kind: .submit, selector: "form"))

        #expect(queue.count == 3)
    }

    @Test func queueDrainsStrictlyInOrder() {
        var queue = FollowLeaderQueue()
        let kinds: [FollowLeaderAction.Kind] = [.input, .check, .click, .key, .submit]
        for (offset, kind) in kinds.enumerated() {
            queue.enqueue(FollowLeaderAction(seq: offset, kind: kind, selector: "el\(offset)"))
        }
        var drained: [FollowLeaderAction.Kind] = []
        while let next = queue.dequeue() { drained.append(next.kind) }
        #expect(drained == kinds)
    }

    @Test func removeAllClearsPendingWork() {
        var queue = FollowLeaderQueue()
        queue.enqueue(typing("john", seq: 1))
        queue.enqueue(FollowLeaderAction(seq: 2, kind: .click))
        queue.removeAll()
        #expect(queue.isEmpty)
        #expect(queue.dequeue() == nil)
    }

    // MARK: - Payload parsing

    @Test func parsesARecordedClickPayload() {
        let payload: [String: Any] = [
            "kind": "click",
            "selector": "form > button",
            "frame": "https://example.com/login",
            "topFrame": true,
            "hint": ["tag": "BUTTON", "text": "Sign in", "type": "SUBMIT"]
        ]
        let action = FollowLeaderAction(payload: payload, seq: 7)
        #expect(action?.kind == .click)
        #expect(action?.seq == 7)
        #expect(action?.hint.text == "Sign in")
        // Tag and type are lowercased so scoring compares like with like.
        #expect(action?.hint.tag == "button")
        #expect(action?.hint.type == "submit")
    }

    @Test func rejectsPayloadsWithNoUsableKind() {
        #expect(FollowLeaderAction(payload: ["kind": "teleport"], seq: 1) == nil)
        #expect(FollowLeaderAction(payload: [:], seq: 1) == nil)
    }

    @Test func scrollCoordinatesSurviveNumericBridging() {
        let payload: [String: Any] = ["kind": "scroll", "x": 0, "y": Double(1280)]
        let action = FollowLeaderAction(payload: payload, seq: 1)
        #expect(action?.scrollY == 1280)
    }

    @Test func jsArgumentsCarryEveryFieldTheEngineReads() {
        let action = FollowLeaderAction(
            seq: 1,
            kind: .select,
            selector: "select#country",
            value: "GB",
            hint: hint(id: "country", tag: "select")
        )
        let args = action.jsArguments
        #expect(args["kind"] as? String == "select")
        #expect(args["value"] as? String == "GB")
        #expect((args["hint"] as? [String: Any])?["id"] as? String == "country")
    }

    // MARK: - Apply outcome

    @Test func unverifiedButActedClickCountsAsSuccess() {
        // A benign tap (a tab, a toggle) produces no page change. Treating it
        // as a failure would fire the same click up to three times.
        let outcome = FollowLeaderApplyOutcome(
            jsResult: ["ok": true, "verified": false, "method": "attempted"] as [String: Any]
        )
        #expect(outcome.ok)
        #expect(!outcome.verified)
    }

    @Test func aDeliveredPressIsNeverRetried() {
        // The strongest single-press guarantee: the engine proved the
        // activation reached the control, so even with nothing visible on
        // screen this must count as done. Retrying is a second add-to-cart.
        let outcome = FollowLeaderApplyOutcome(
            jsResult: ["ok": true, "verified": false, "method": "delivered", "reason": "nativeClick"] as [String: Any]
        )
        #expect(outcome.ok)
        #expect(!outcome.verified)
        #expect(outcome.wasDelivered)
    }

    @Test func onlyADeliveredOutcomeCarriesTheDeliveryMarker() {
        let attempted = FollowLeaderApplyOutcome(
            jsResult: ["ok": true, "verified": false, "method": "attempted"] as [String: Any]
        )
        let missed = FollowLeaderApplyOutcome(
            jsResult: ["ok": false, "verified": false, "method": "delivered"] as [String: Any]
        )
        #expect(!attempted.wasDelivered)
        // A failure can never be "delivered" — that pairing would silence a
        // real miss instead of retrying it.
        #expect(!missed.wasDelivered)
    }

    @Test func aPressThatNeverLandedStillRetries() {
        // Covered by an overlay, disabled, detached from the document: no
        // technique delivered anything, so this is a genuine miss.
        let outcome = FollowLeaderApplyOutcome(
            jsResult: ["ok": false, "verified": false, "method": "attempted"] as [String: Any]
        )
        #expect(!outcome.ok)
        #expect(!outcome.wasDelivered)
    }

    @Test func unreadableResultIsAFailureSoItRetries() {
        let outcome = FollowLeaderApplyOutcome(jsResult: "not-a-dictionary")
        #expect(!outcome.ok)
        #expect(outcome.reason == "unreadable-result")
    }

    @Test func missingElementIsAFailure() {
        let outcome = FollowLeaderApplyOutcome(
            jsResult: ["ok": false, "verified": false, "reason": "not-found"] as [String: Any]
        )
        #expect(!outcome.ok)
        #expect(outcome.reason == "not-found")
    }

    // MARK: - Drift resync

    @Test func identicalPagesNeverResync() {
        let leader = URL(string: "https://example.com/account")
        let follower = URL(string: "https://example.com/account")
        #expect(!FollowLeaderSync.needsResync(leader: leader, follower: follower))
    }

    @Test func querySringsAndTrailingSlashesAreNotDrift() {
        // Sites append per-session tokens constantly; treating those as drift
        // would put every follower into a reload loop.
        let leader = URL(string: "https://example.com/account")
        let follower = URL(string: "https://www.example.com/account/?session=abc123#top")
        #expect(!FollowLeaderSync.needsResync(leader: leader, follower: follower))
    }

    @Test func aDifferentPathIsDrift() {
        let leader = URL(string: "https://example.com/dashboard")
        let follower = URL(string: "https://example.com/login")
        #expect(FollowLeaderSync.needsResync(leader: leader, follower: follower))
    }

    @Test func aDifferentHostIsDrift() {
        let leader = URL(string: "https://example.com/account")
        let follower = URL(string: "https://accounts.google.com/account")
        #expect(FollowLeaderSync.needsResync(leader: leader, follower: follower))
    }

    @Test func aBlankFollowerIsPulledOntoTheLeaderPage() {
        let leader = URL(string: "https://example.com/account")
        #expect(FollowLeaderSync.needsResync(leader: leader, follower: nil))
    }

    @Test func anUnknownLeaderPageNeverTriggersAResync() {
        #expect(!FollowLeaderSync.needsResync(leader: nil, follower: URL(string: "https://example.com")))
        let aboutBlank = URL(string: "about:blank")
        #expect(!FollowLeaderSync.needsResync(leader: aboutBlank, follower: URL(string: "https://example.com")))
    }

    @Test func normalizedKeyIgnoresCaseAndWWW() {
        let a = FollowLeaderSync.normalizedKey(URL(string: "HTTPS://WWW.Example.COM/Account/"))
        let b = FollowLeaderSync.normalizedKey(URL(string: "https://example.com/account"))
        #expect(a == b)
    }

    // MARK: - Mirroring pace

    @Test func everyProfileKeepsSixteenWindowsWithinASecondOrTwo() {
        for profile in SpeedProfile.allCases {
            // 15 followers, worst-case position, capped by the ceiling.
            let worst = min(
                profile.followLeaderMaxStagger.seconds,
                profile.followLeaderStaggerStep.seconds * 15
            )
            #expect(worst <= 2.0)
        }
    }

    @Test func turboIsEffectivelySimultaneous() {
        #expect(SpeedProfile.turbo.followLeaderStaggerStep.seconds == 0)
        #expect(SpeedProfile.turbo.followLeaderMaxStagger.seconds == 0)
    }

    @Test func paceGetsStrictlyFasterUpTheDial() {
        let ordered: [SpeedProfile] = [.slow, .normal, .fast, .turbo]
        for pair in zip(ordered, ordered.dropFirst()) {
            let slower = pair.0.followLeaderStaggerStep.seconds
            let faster = pair.1.followLeaderStaggerStep.seconds
            #expect(faster < slower)
        }
    }

    @Test func everyProfileBeatsTheOldOneSecondPerWindowCascade() {
        for profile in SpeedProfile.allCases {
            #expect(profile.followLeaderStaggerStep.seconds < 1.0)
        }
    }

    @Test func actionTimeoutIsASafetyWatchdogAndNeverShrinks() {
        // A fast dial trims pacing, never the watchdog that stops one wedged
        // window from blocking everything queued behind it.
        let base = SpeedProfile.normal.followLeaderActionTimeout.seconds
        for profile in SpeedProfile.allCases {
            #expect(profile.followLeaderActionTimeout.seconds >= base)
        }
        #expect(SpeedProfile.slow.followLeaderActionTimeout.seconds > base)
    }

    @Test func retryBackoffStaysShortEnoughToRecoverInline() {
        for profile in SpeedProfile.allCases {
            let backoff = profile.followLeaderRetryBackoff.seconds
            #expect(backoff > 0)
            #expect(backoff <= 0.5)
        }
    }

    // MARK: - Head start is charged once per catch-up

    @Test func aTwentyStepLoginCostsTheSameHeadStartAsOneStep() {
        // The regression this pins down: the lead-in used to be charged
        // before *every* action, so the last window of a Slow grid fell two
        // seconds further behind on each step — forty seconds over a twenty
        // step login.
        let step = SpeedProfile.slow.followLeaderStaggerStep.seconds
        let cap = SpeedProfile.slow.followLeaderMaxStagger.seconds
        let one = FollowLeaderPacing.totalLead(actionCount: 1, position: 15, step: step, cap: cap)
        let twenty = FollowLeaderPacing.totalLead(actionCount: 20, position: 15, step: step, cap: cap)

        #expect(one == twenty)
        #expect(twenty <= cap)
    }

    @Test func noCatchUpMeansNoHeadStartAtAll() {
        let lead = FollowLeaderPacing.totalLead(actionCount: 0, position: 9, step: 0.25, cap: 2.0)
        #expect(lead == 0)
    }

    @Test func theFirstFollowerNeverWaits() {
        #expect(FollowLeaderPacing.leadIn(position: 0, step: 0.25, cap: 2.0) == 0)
    }

    @Test func theHeadStartRipplesDownTheGridAndThenStops() {
        let step = 0.25
        let cap = 2.0
        let second = FollowLeaderPacing.leadIn(position: 1, step: step, cap: cap)
        let fifth = FollowLeaderPacing.leadIn(position: 4, step: step, cap: cap)
        let last = FollowLeaderPacing.leadIn(position: 15, step: step, cap: cap)

        #expect(second == 0.25)
        #expect(fifth == 1.0)
        // Capped, not step × 15 = 3.75s.
        #expect(last == cap)
    }

    @Test func turboGivesEveryWindowAZeroHeadStart() {
        let step = SpeedProfile.turbo.followLeaderStaggerStep.seconds
        let cap = SpeedProfile.turbo.followLeaderMaxStagger.seconds
        for position in 0..<16 {
            #expect(FollowLeaderPacing.leadIn(position: position, step: step, cap: cap) == 0)
        }
    }

    @Test func everyDialKeepsAFullGridCatchUpUnderTwoSeconds() {
        for profile in SpeedProfile.allCases {
            let lead = FollowLeaderPacing.leadIn(
                position: 15,
                step: profile.followLeaderStaggerStep.seconds,
                cap: profile.followLeaderMaxStagger.seconds
            )
            #expect(lead <= 2.0)
        }
    }

    // MARK: - Crash recovery

    @Test func aRecoveringWindowHoldsItsQueue() {
        // A dead web process must hold the queue exactly like a page load
        // does. Without this every queued action burned three attempts and a
        // full timeout before being counted as a miss.
        #expect(FollowLeaderReadiness.shouldHold(isLoading: false, isRestoringSession: false, isRecovering: true))
    }

    @Test func aHealthyWindowIsNeverHeld() {
        #expect(!FollowLeaderReadiness.shouldHold(isLoading: false, isRestoringSession: false, isRecovering: false))
    }

    @Test func loadingAndSessionRestoreStillHold() {
        #expect(FollowLeaderReadiness.shouldHold(isLoading: true, isRestoringSession: false, isRecovering: false))
        #expect(FollowLeaderReadiness.shouldHold(isLoading: false, isRestoringSession: true, isRecovering: false))
    }

    @Test @MainActor func aFreshWindowStartsHealthyAndUncrashed() {
        let session = QuadSession(index: 3)
        #expect(!session.flRecovering)
        #expect(session.flCrashCount == 0)
    }
}

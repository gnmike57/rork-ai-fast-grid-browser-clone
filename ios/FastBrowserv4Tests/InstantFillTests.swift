import Foundation
import Testing
@testable import FastBrowserv4

/// Instant Fill's pure logic: what survives an audit, how a field is described
/// to a follower, and how a rotating window's card replaces the leader's.
struct InstantFillTests {

    // MARK: - Parsing

    @Test
    func fieldParsesEveryDescriptor() throws {
        let field = try #require(InstantFillField([
            "selector": "form > input:nth-of-type(2)",
            "frame": "https://example.com/checkout",
            "index": 3,
            "tag": "input",
            "type": "email",
            "name": "user_email",
            "id": "email",
            "placeholder": "you@example.com",
            "aria": "Email address",
            "autocomplete": "email",
            "label": "email address",
            "value": "someone@example.com",
            "isEditable": false
        ]))
        #expect(field.selector == "form > input:nth-of-type(2)")
        #expect(field.index == 3)
        #expect(field.name == "user_email")
        #expect(field.value == "someone@example.com")
        #expect(field.frame == "https://example.com/checkout")
    }

    /// A row with no selector, no name, no id and no position cannot be found
    /// again in another window, so it must never enter a fill.
    @Test
    func fieldRejectsAnEntryNothingCouldEverMatch() {
        #expect(InstantFillField(["value": "orphan"]) == nil)
        #expect(InstantFillField([:]) == nil)
        // Any single one of the four is enough to locate it.
        #expect(InstantFillField(["name": "user"]) != nil)
        #expect(InstantFillField(["index": 0]) != nil)
    }

    @Test
    func snapshotParsesRowsAndDropsMalformedOnes() {
        let snapshot = InstantFillSnapshot(jsResult: [
            "scanned": 9,
            "fields": [
                ["name": "user", "value": "abc"],
                ["value": "no-way-to-find-me"],
                ["id": "pw", "value": "secret"]
            ]
        ])
        #expect(snapshot.fields.count == 2)
        #expect(snapshot.scanned == 9)
        #expect(!snapshot.isEmpty)
    }

    /// An unreadable result yields nothing rather than something partial —
    /// filling half a form because the rest failed to parse is worse than not
    /// filling at all.
    @Test
    func snapshotFromGarbageIsEmptyRatherThanPartial() {
        #expect(InstantFillSnapshot(jsResult: "not a dictionary").isEmpty)
        #expect(InstantFillSnapshot(jsResult: nil).isEmpty)
        #expect(InstantFillSnapshot(jsResult: ["fields": "wrong type"]).isEmpty)
    }

    @Test
    func snapshotRoundTripsThroughItsJavaScriptArguments() throws {
        let field = InstantFillField(name: "cardnumber", value: "4111111111111111", index: 2)
        let snapshot = InstantFillSnapshot(fields: [field])
        let rows = try #require(snapshot.jsArguments["fields"] as? [[String: Any]])
        let rebuilt = try #require(InstantFillField(rows[0]))
        #expect(rebuilt == field)
    }

    // MARK: - Card substitution

    private func cardPayload() -> CardFillPayload {
        CardFillPayload(
            record: CardRecord(
                id: "card-1",
                cardholderName: "Jane Roe",
                last4: "4242",
                brand: .visa,
                expMonth: 7,
                expYear: 2029
            ),
            secrets: CardSecrets(number: "4242424242424242", securityCode: "123")
        )
    }

    /// The promise that keeps a rotating window on its own card: every part of
    /// the card is swapped together, so no window ever ends up with one card's
    /// number and another's expiry.
    @Test
    func substitutionReplacesEveryPartOfTheCardTogether() {
        let snapshot = InstantFillSnapshot(fields: [
            InstantFillField(autocomplete: "cc-number", value: "4111111111111111"),
            InstantFillField(autocomplete: "cc-csc", value: "999"),
            InstantFillField(autocomplete: "cc-name", value: "John Doe"),
            InstantFillField(autocomplete: "cc-exp", value: "01/26")
        ])
        let swapped = snapshot.substitutingCard(cardPayload())
        #expect(swapped.fields[0].value == "4242424242424242")
        #expect(swapped.fields[1].value == "123")
        #expect(swapped.fields[2].value == "Jane Roe")
        #expect(swapped.fields[3].value == "07/26")
    }

    /// Everything that is not a card field travels exactly as the leader had
    /// it. A username is not a card number.
    @Test
    func substitutionLeavesNonCardFieldsUntouched() {
        let snapshot = InstantFillSnapshot(fields: [
            InstantFillField(name: "username", value: "jane"),
            InstantFillField(type: "password", name: "password", value: "hunter2"),
            InstantFillField(name: "search", value: "mm")
        ])
        let swapped = snapshot.substitutingCard(cardPayload())
        #expect(swapped.fields == snapshot.fields)
    }

    /// A cleared field stays cleared. Substituting a full number into a box the
    /// user just emptied would fight them.
    @Test
    func substitutionKeepsAClearedCardFieldCleared() {
        let snapshot = InstantFillSnapshot(fields: [
            InstantFillField(autocomplete: "cc-number", value: "")
        ])
        #expect(snapshot.substitutingCard(cardPayload()).fields[0].value.isEmpty)
    }

    /// With no card resolved for a window there is nothing to substitute, so
    /// the snapshot passes through rather than blanking the card boxes.
    @Test
    func substitutionWithoutACardIsAPassThrough() {
        let snapshot = InstantFillSnapshot(fields: [
            InstantFillField(autocomplete: "cc-number", value: "4111111111111111")
        ])
        #expect(snapshot.substitutingCard(nil) == snapshot)
    }

    /// A substituted select can no longer be matched on the leader's option
    /// wording, so that hint is dropped rather than left to mislead.
    @Test
    func substitutedSelectDropsTheLeadersOptionText() {
        let snapshot = InstantFillSnapshot(fields: [
            InstantFillField(
                autocomplete: "cc-exp-month",
                value: "01",
                optionText: "January",
                isSelect: true
            )
        ])
        let swapped = snapshot.substitutingCard(cardPayload())
        #expect(swapped.fields[0].value == "07")
        #expect(swapped.fields[0].optionText.isEmpty)
    }

    @Test
    func containsCardFieldsSeesOnlyRealCardFields() {
        #expect(InstantFillSnapshot(fields: [
            InstantFillField(name: "username", value: "jane")
        ]).containsCardFields == false)
        #expect(InstantFillSnapshot(fields: [
            InstantFillField(autocomplete: "cc-number", value: "4111111111111111")
        ]).containsCardFields)
    }

    // MARK: - Reporting

    /// Each failure has to read differently. "Nothing filled in yet", "no form
    /// here" and "the other windows don't have these boxes" are three genuinely
    /// different situations, and collapsing them is what makes a button feel
    /// broken.
    @Test
    func everyOutcomeReportsItselfDistinctly() {
        #expect(InstantFillSummary().toastMessage == "No other windows to fill")

        var noForm = InstantFillSummary()
        noForm.windows = 3
        #expect(noForm.toastMessage == "No form on this page to copy")

        var emptyForm = InstantFillSummary()
        emptyForm.windows = 3
        emptyForm.leaderScanned = 6
        #expect(emptyForm.toastMessage == "Nothing filled in yet — fill this window first")

        var noMatches = InstantFillSummary()
        noMatches.windows = 3
        noMatches.leaderScanned = 6
        noMatches.sourceFields = 4
        noMatches.missed = 12
        #expect(noMatches.toastMessage == "No matching fields in the other windows")

        var alreadyMatching = InstantFillSummary()
        alreadyMatching.windows = 3
        alreadyMatching.leaderScanned = 6
        alreadyMatching.sourceFields = 4
        #expect(alreadyMatching.toastMessage == "Other windows already match")

        var filled = InstantFillSummary()
        filled.windows = 3
        filled.leaderScanned = 6
        filled.sourceFields = 4
        filled.windowsFilled = 3
        filled.filled = 12
        #expect(filled.toastMessage == "Filled 12 fields across 3 windows")
    }

    @Test
    func singularsReadCorrectly() {
        var one = InstantFillSummary()
        one.windows = 1
        one.leaderScanned = 2
        one.sourceFields = 1
        one.windowsFilled = 1
        one.filled = 1
        #expect(one.toastMessage == "Filled 1 field across 1 window")
    }

    @Test
    func outcomeParsesAndFailsSafely() {
        let good = InstantFillOutcome(jsResult: ["found": 5, "filled": 4, "missed": 1])
        #expect(good.found == 5)
        #expect(good.filled == 4)
        #expect(good.missed == 1)
        #expect(good.didReachAnything)

        let bad = InstantFillOutcome(jsResult: "nonsense")
        #expect(bad.reason == "unreadable-result")
        #expect(!bad.didReachAnything)
    }
}

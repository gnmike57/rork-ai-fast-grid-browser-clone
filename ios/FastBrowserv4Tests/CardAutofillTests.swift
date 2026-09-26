//
//  CardAutofillTests.swift
//  FastBrowserv4Tests
//
//  Card autofill: how cards spread across windows, how a checkout field is
//  recognised, and how a rotate-mode follower swaps the leader's card for its
//  own. Plus the three Follow the Leader review fixes shipped alongside it.
//

import Testing
import Foundation
import CoreGraphics
@testable import FastBrowserv4

struct CardAutofillTests {

    // MARK: - Assignment: rotate

    /// The headline rule. Six windows, two cards: the list repeats rather than
    /// leaving four windows empty.
    @Test func rotateRepeatsWhenThereAreFewerCardsThanWindows() {
        let plan = CardAssignment.plan(
            windowIndices: [0, 1, 2, 3, 4, 5],
            cardCount: 2,
            offset: 0,
            mode: .rotate
        )
        #expect(plan[0] == 0)
        #expect(plan[1] == 1)
        #expect(plan[2] == 0)
        #expect(plan[3] == 1)
        #expect(plan[4] == 0)
        #expect(plan[5] == 1)
    }

    /// Eight windows, three cards — the case the plan was reviewed against.
    @Test func rotateCyclesAcrossEightWindowsWithThreeCards() {
        let expected = [0, 1, 2, 0, 1, 2, 0, 1]
        for position in 0..<8 {
            let index = CardAssignment.cardIndex(
                position: position, cardCount: 3, offset: 0, mode: .rotate
            )
            #expect(index == expected[position])
        }
    }

    @Test func rotateGivesEveryWindowItsOwnCardWhenThereAreEnough() {
        let plan = CardAssignment.plan(
            windowIndices: [0, 1, 2, 3],
            cardCount: 6,
            offset: 0,
            mode: .rotate
        )
        let assigned = Set(plan.values)
        #expect(assigned.count == 4)
        #expect(plan[3] == 3)
    }

    // MARK: - Assignment: same as leader

    @Test func sameAsLeaderGivesEveryWindowOneCard() {
        let plan = CardAssignment.plan(
            windowIndices: [0, 1, 2, 3, 4, 5, 6, 7],
            cardCount: 4,
            offset: 0,
            mode: .sameAsLeader
        )
        #expect(plan.count == 8)
        let distinct = Set(plan.values)
        #expect(distinct == [0])
    }

    /// Advancing the rotation still moves same-as-leader onto the next card —
    /// every window together, which is the whole point of the mode.
    @Test func sameAsLeaderFollowsTheRotationOffsetAsOneBlock() {
        let plan = CardAssignment.plan(
            windowIndices: [0, 1, 2, 3],
            cardCount: 3,
            offset: 2,
            mode: .sameAsLeader
        )
        #expect(Set(plan.values) == [2])
    }

    // MARK: - Assignment: edges

    @Test func emptyWalletAssignsNothing() {
        let index = CardAssignment.cardIndex(position: 0, cardCount: 0, offset: 0, mode: .rotate)
        #expect(index == nil)
        let plan = CardAssignment.plan(windowIndices: [0, 1], cardCount: 0, offset: 0, mode: .rotate)
        #expect(plan.isEmpty)
    }

    /// A disabled window (the 3×3 centre in dual-site) is simply absent from
    /// the order, so it never consumes a card and never shifts the others.
    @Test func skippedWindowsDoNotConsumeACard() {
        let plan = CardAssignment.plan(
            windowIndices: [0, 1, 2, 3, 5, 6, 7, 8],
            cardCount: 3,
            offset: 0,
            mode: .rotate
        )
        #expect(plan[4] == nil)
        #expect(plan[5] == 1)
        #expect(plan.count == 8)
    }

    @Test func nextSetAdvancesByOneAndWrapsAtTheEnd() {
        #expect(CardAssignment.advanced(offset: 0, cardCount: 3) == 1)
        #expect(CardAssignment.advanced(offset: 1, cardCount: 3) == 2)
        #expect(CardAssignment.advanced(offset: 2, cardCount: 3) == 0)
    }

    @Test func nextSetOnAnEmptyWalletStaysAtZero() {
        #expect(CardAssignment.advanced(offset: 4, cardCount: 0) == 0)
    }

    /// A wallet that shrank must never index backwards off the front.
    @Test func staleOffsetFromALargerWalletStaysInRange() {
        let index = CardAssignment.cardIndex(position: 0, cardCount: 2, offset: 9, mode: .rotate)
        #expect(index == 1)
        let negative = CardAssignment.cardIndex(position: 0, cardCount: 3, offset: -1, mode: .rotate)
        #expect(negative == 2)
    }

    // MARK: - Brand detection

    @Test func brandsAreDetectedFromTheNumberPrefix() {
        #expect(CardBrand.detect(from: "4111 1111 1111 1111") == .visa)
        #expect(CardBrand.detect(from: "5500 0000 0000 0004") == .mastercard)
        #expect(CardBrand.detect(from: "2221 0000 0000 0009") == .mastercard)
        #expect(CardBrand.detect(from: "3782 822463 10005") == .amex)
        #expect(CardBrand.detect(from: "6011 0000 0000 0004") == .discover)
        #expect(CardBrand.detect(from: "3056 9309 0259 04") == .diners)
        #expect(CardBrand.detect(from: "3530 1113 3330 0000") == .jcb)
        #expect(CardBrand.detect(from: "") == .unknown)
    }

    @Test func amexUsesAFourDigitSecurityCode() {
        #expect(CardBrand.amex.securityCodeLength == 4)
        #expect(CardBrand.visa.securityCodeLength == 3)
    }

    // MARK: - Number helpers

    @Test func numbersFormatByBrandGrouping() {
        #expect(CardNumber.formatted("4111111111111111") == "4111 1111 1111 1111")
        // Amex groups 4-6-5, not 4-4-4-4.
        #expect(CardNumber.formatted("378282246310005") == "3782 822463 10005")
    }

    @Test func maskedNumbersOnlyEverShowTheLastFour() {
        let masked = CardNumber.masked(last4: "4242", brand: .visa)
        #expect(masked.hasSuffix("4242"))
        #expect(!masked.contains("1111"))
        let digitCount = masked.filter(\.isNumber).count
        #expect(digitCount == 4)
    }

    @Test func luhnAcceptsRealNumbersAndRejectsTypos() {
        #expect(CardNumber.passesLuhn("4111 1111 1111 1111"))
        #expect(!CardNumber.passesLuhn("4111 1111 1111 1112"))
        // Too short to judge — treated as failing rather than passing.
        #expect(!CardNumber.passesLuhn("4111"))
    }

    @Test func digitsSurviveAnyFormatting() {
        #expect(CardNumber.digits("4111-1111 1111.1111") == "4111111111111111")
        #expect(CardNumber.last4("4111 1111 1111 4242") == "4242")
    }

    // MARK: - Field classification

    @Test func autocompleteTokensAreTrustedFirst() {
        #expect(kind(autocomplete: "cc-number") == .number)
        #expect(kind(autocomplete: "cc-exp") == .expiryCombined)
        #expect(kind(autocomplete: "cc-exp-month") == .expiryMonth)
        #expect(kind(autocomplete: "cc-exp-year") == .expiryYear)
        #expect(kind(autocomplete: "cc-csc") == .securityCode)
        #expect(kind(autocomplete: "cc-name") == .cardholderName)
    }

    /// Real checkouts prefix the token with a section or billing scope.
    @Test func scopedAutocompleteTokensStillClassify() {
        #expect(kind(autocomplete: "billing cc-number") == .number)
        #expect(kind(autocomplete: "section-payment shipping cc-csc") == .securityCode)
    }

    @Test func fieldNamesAndPlaceholdersAreTheFallback() {
        #expect(kind(name: "card_number") == .number)
        #expect(kind(name: "cardNumber") == .number)
        #expect(kind(id: "credit-card-num") == .number)
        #expect(kind(placeholder: "MM / YY") == .expiryCombined)
        #expect(kind(label: "Security code") == .securityCode)
        #expect(kind(name: "cvv2") == .securityCode)
        #expect(kind(name: "nameOnCard") == .cardholderName)
    }

    /// "Card verification code" contains "card", which must not drag it into
    /// the number branch.
    @Test func securityCodeWinsOverTheWordCard() {
        #expect(kind(label: "Card verification code") == .securityCode)
        #expect(kind(name: "card_cvc") == .securityCode)
    }

    @Test func expiryHalvesAreToldApart() {
        #expect(kind(name: "exp_month") == .expiryMonth)
        #expect(kind(name: "exp_year") == .expiryYear)
        // Both halves named in one box means the site wants MM/YY together.
        #expect(kind(name: "expiry_month_year") == .expiryCombined)
    }

    @Test func nonCardFieldsAreLeftAlone() {
        #expect(kind(name: "search") == nil)
        #expect(kind(name: "username") == nil)
        #expect(kind(name: "address_line1") == nil)
    }

    /// Substring matching on short tokens is how autofill goes wrong. "mm"
    /// hides inside "summary", "mon" inside "money" and "monitor", "cid"
    /// inside "accident", "pan" inside "company" — every one of these would
    /// have taken card data if the hint were matched naively.
    @Test func innocentFieldsAreNeverMistakenForCardFields() {
        #expect(kind(name: "summary") == nil)
        #expect(kind(name: "order_summary") == nil)
        #expect(kind(name: "money") == nil)
        #expect(kind(name: "monitor") == nil)
        #expect(kind(label: "Accident report") == nil)
        #expect(kind(name: "company") == nil)
        #expect(kind(label: "Comments") == nil)
        #expect(kind(name: "yyz_airport") == nil)
    }

    /// A bare month or year box is accepted only when that is the entire
    /// description, or when the field is demonstrably about a card.
    @Test func bareMonthAndYearNeedContextOrAnExactMatch() {
        #expect(kind(name: "mm") == .expiryMonth)
        #expect(kind(name: "yy") == .expiryYear)
        #expect(kind(placeholder: "MM") == .expiryMonth)
        #expect(kind(name: "card_month") == .expiryMonth)
        #expect(kind(name: "card_year") == .expiryYear)
        // No card or expiry context anywhere, and not an exact token.
        #expect(kind(name: "birth_month_field") == nil)
    }

    /// A password box is never a card field, whatever it happens to be called.
    @Test func passwordFieldsAreNeverCardFields() {
        var hint = FollowLeaderHint()
        hint.type = "password"
        hint.name = "card_number"
        #expect(CardFieldKind.classify(hint: hint) == nil)
    }

    /// Selects only ever stand in for the two expiry halves — a dropdown is
    /// never asking for a card number.
    @Test func selectsOnlyResolveToExpiryHalves() {
        var month = FollowLeaderHint()
        month.tag = "select"
        month.name = "expiryMonth"
        #expect(CardFieldKind.classify(hint: month) == .expiryMonth)

        var bogus = FollowLeaderHint()
        bogus.tag = "select"
        bogus.name = "card_number"
        #expect(CardFieldKind.classify(hint: bogus) == nil)
    }

    // MARK: - Follow the Leader substitution

    private var testCard: CardFillPayload {
        CardFillPayload(
            record: CardRecord(
                id: "card-1",
                cardholderName: "Ada Lovelace",
                last4: "4242",
                brand: .visa,
                expMonth: 7,
                expYear: 2029
            ),
            secrets: CardSecrets(number: "4242424242424242", securityCode: "737")
        )
    }

    @Test func rotateSwapsInTheFollowersOwnNumber() {
        var hint = FollowLeaderHint()
        hint.autocomplete = "cc-number"
        let action = FollowLeaderAction(seq: 1, kind: .input, value: "4111111111111111", hint: hint)
        let out = CardSubstitution.substitute(action, with: testCard)
        #expect(out.value == "4242424242424242")
    }

    /// Every card field comes from the same card, so a window can never end up
    /// with one card's number and another's expiry.
    @Test func everyFieldComesFromTheSameCard() {
        let card = testCard
        func substituted(_ autocomplete: String, _ leaderValue: String) -> String {
            var hint = FollowLeaderHint()
            hint.autocomplete = autocomplete
            let action = FollowLeaderAction(seq: 1, kind: .input, value: leaderValue, hint: hint)
            return CardSubstitution.substitute(action, with: card).value
        }
        #expect(substituted("cc-number", "4111111111111111") == "4242424242424242")
        #expect(substituted("cc-csc", "123") == "737")
        #expect(substituted("cc-name", "Grace Hopper") == "Ada Lovelace")
        #expect(substituted("cc-exp-month", "01") == "07")
        #expect(substituted("cc-exp", "01/26") == "07/29")
    }

    /// Clearing a box is mirrored as a clear. Substituting a full number into
    /// a field the user just emptied would fight them.
    @Test func clearingAFieldStaysCleared() {
        var hint = FollowLeaderHint()
        hint.autocomplete = "cc-number"
        let action = FollowLeaderAction(seq: 1, kind: .input, value: "", hint: hint)
        #expect(CardSubstitution.substitute(action, with: testCard).value == "")
    }

    /// A two-digit year box must never receive a four-digit year.
    @Test func yearWidthMatchesWhatTheLeaderIsTyping() {
        var hint = FollowLeaderHint()
        hint.autocomplete = "cc-exp-year"
        let short = FollowLeaderAction(seq: 1, kind: .input, value: "26", hint: hint)
        #expect(CardSubstitution.substitute(short, with: testCard).value == "29")
        let long = FollowLeaderAction(seq: 2, kind: .input, value: "2026", hint: hint)
        #expect(CardSubstitution.substitute(long, with: testCard).value == "2029")
    }

    /// A site expecting "MM / YY" still gets its own separator back.
    @Test func combinedExpiryKeepsTheLeadersSeparator() {
        var hint = FollowLeaderHint()
        hint.autocomplete = "cc-exp"
        let spaced = FollowLeaderAction(seq: 1, kind: .input, value: "01 / 26", hint: hint)
        #expect(CardSubstitution.substitute(spaced, with: testCard).value == "07 / 29")
        let bare = FollowLeaderAction(seq: 2, kind: .input, value: "0126", hint: hint)
        #expect(CardSubstitution.substitute(bare, with: testCard).value == "07/29")
    }

    /// Partial typing substitutes the whole value, so a follower is never left
    /// holding half a number when the leader pauses mid-field.
    @Test func partialTypingSubstitutesTheCompleteValue() {
        var hint = FollowLeaderHint()
        hint.autocomplete = "cc-number"
        let partial = FollowLeaderAction(seq: 1, kind: .input, value: "4111", hint: hint)
        #expect(CardSubstitution.substitute(partial, with: testCard).value == "4242424242424242")
    }

    /// Anything that is not a card input passes straight through untouched.
    @Test func nonCardActionsAreNeverRewritten() {
        var hint = FollowLeaderHint()
        hint.name = "username"
        let typing = FollowLeaderAction(seq: 1, kind: .input, value: "ada@example.com", hint: hint)
        #expect(CardSubstitution.substitute(typing, with: testCard) == typing)

        var cardHint = FollowLeaderHint()
        cardHint.autocomplete = "cc-number"
        // A click on a card field is still a click — only values are swapped.
        let click = FollowLeaderAction(seq: 2, kind: .click, value: "4111", hint: cardHint)
        #expect(CardSubstitution.substitute(click, with: testCard) == click)
    }

    // MARK: - Fill reporting

    /// A checkout with nothing to fill has to read differently from a
    /// successful fill — silence there is what makes an autofill button feel
    /// broken.
    @Test func aPageWithNoCardFieldsSaysSo() {
        let summary = CardFillSummary(windows: 4, windowsWithFields: 0, found: 0, filled: 0)
        #expect(summary.toastMessage == "No card fields on this page")
    }

    @Test func aSuccessfulFillReportsWindowsAndFields() {
        let summary = CardFillSummary(windows: 6, windowsWithFields: 6, found: 24, filled: 24)
        #expect(summary.toastMessage == "Filled 6 windows · 24 card fields")
    }

    @Test func oneWindowAndOneFieldReadNaturally() {
        let summary = CardFillSummary(windows: 1, windowsWithFields: 1, found: 1, filled: 1)
        #expect(summary.toastMessage == "Filled 1 window · 1 card field")
    }

    @Test func anEmptyWalletIsReportedRatherThanIgnored() {
        let summary = CardFillSummary(missingCards: 4)
        #expect(summary.toastMessage == "No card saved yet")
    }

    @Test func outcomesFromSeveralWindowsAddUp() {
        let a = CardFillOutcome(found: 4, filled: 4)
        let b = CardFillOutcome(found: 3, filled: 1)
        let total = a + b
        #expect(total.found == 7)
        #expect(total.filled == 5)
    }

    /// A field that already held the right value counts as found, not filled —
    /// and that is still a success.
    @Test func alreadyCorrectFieldsCountAsFoundNotFilled() {
        let outcome = CardFillOutcome(jsResult: ["found": 4, "filled": 0])
        #expect(outcome.found == 4)
        #expect(outcome.filled == 0)
        #expect(outcome.didFindFields)
    }

    @Test func anUnreadableResultIsNotTreatedAsASuccess() {
        let outcome = CardFillOutcome(jsResult: "nonsense")
        #expect(!outcome.didFindFields)
        #expect(outcome.reason == "unreadable-result")
    }

    // MARK: - Expiry entry

    @Test func expiryFormatsItselfAsItIsTyped() {
        #expect(CardFormView.formatExpiry("0") == "0")
        // A lone digit above 1 can only be a padded month.
        #expect(CardFormView.formatExpiry("7") == "07/")
        #expect(CardFormView.formatExpiry("12") == "12")
        #expect(CardFormView.formatExpiry("1229") == "12/29")
        #expect(CardFormView.formatExpiry("12/29") == "12/29")
        #expect(CardFormView.formatExpiry("") == "")
    }

    // MARK: - Expiry state

    @Test func expiredCardsAreRecognisedByMonthNotJustYear() {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        let now = Calendar.current.date(from: components) ?? Date()

        let lastMonth = CardRecord(id: "a", cardholderName: "", last4: "1", brand: .visa, expMonth: 5, expYear: 2026)
        let thisMonth = CardRecord(id: "b", cardholderName: "", last4: "2", brand: .visa, expMonth: 6, expYear: 2026)
        let nextYear = CardRecord(id: "c", cardholderName: "", last4: "3", brand: .visa, expMonth: 1, expYear: 2027)

        #expect(lastMonth.isExpired(asOf: now))
        // The month of expiry is still good — cards die at the end of it.
        #expect(!thisMonth.isExpired(asOf: now))
        #expect(!nextYear.isExpired(asOf: now))
    }

    @Test func twoDigitYearsAreTreatedAsThisCentury() {
        let record = CardRecord(id: "a", cardholderName: "", last4: "1", brand: .visa, expMonth: 3, expYear: 29)
        #expect(record.shortYear == "29")
        #expect(record.fullYear == "2029")
        #expect(record.expiryDisplay == "03/29")
    }

    // MARK: - Helpers

    private func kind(
        autocomplete: String = "",
        name: String = "",
        id: String = "",
        placeholder: String = "",
        label: String = ""
    ) -> CardFieldKind? {
        var hint = FollowLeaderHint()
        hint.tag = "input"
        hint.autocomplete = autocomplete
        hint.name = name
        hint.id = id
        hint.placeholder = placeholder
        hint.label = label
        return CardFieldKind.classify(hint: hint)
    }
}

/// The three Follow the Leader issues the 6- and 8-window review turned up.
struct FollowLeaderReviewFixTests {

    private let canvas = CGSize(width: 393, height: 852)

    // MARK: - Peek strip legibility

    /// The bug: seven previews divided evenly left each about a fingernail
    /// wide. They now hold a readable floor instead.
    @Test func eightWindowPreviewsStayReadable() {
        let width = FollowLeaderLayout.peekThumbnailWidth(count: 7, canvasWidth: canvas.width)
        #expect(width >= 68)
    }

    @Test func sixteenWindowPreviewsAlsoHoldTheFloor() {
        let width = FollowLeaderLayout.peekThumbnailWidth(count: 15, canvasWidth: canvas.width)
        #expect(width >= 68)
    }

    /// Small grids are untouched: they already fitted, so they must still
    /// centre rather than start scrolling.
    @Test func smallGridsStillFitAndStayCentred() {
        let scroll = FollowLeaderLayout.peekMaxScroll(count: 3, canvasWidth: canvas.width)
        #expect(scroll == 0)

        let first = FollowLeaderLayout.peekThumbnailFrame(position: 0, count: 3, in: canvas)
        let last = FollowLeaderLayout.peekThumbnailFrame(position: 2, count: 3, in: canvas)
        let leftGap = first.minX
        let rightGap = canvas.width - last.maxX
        #expect(abs(leftGap - rightGap) < 0.5)
    }

    @Test func sixWindowsStillFitWithoutScrolling() {
        let scroll = FollowLeaderLayout.peekMaxScroll(count: 5, canvasWidth: canvas.width)
        #expect(scroll == 0)
    }

    /// Once they no longer fit, the strip scrolls rather than shrinking.
    @Test func eightWindowsOverflowIntoAScrollableStrip() {
        let scroll = FollowLeaderLayout.peekMaxScroll(count: 7, canvasWidth: canvas.width)
        #expect(scroll > 0)
    }

    @Test func scrollingMovesTheThumbnailsAndIsClamped() {
        let maxScroll = FollowLeaderLayout.peekMaxScroll(count: 7, canvasWidth: canvas.width)
        let atRest = FollowLeaderLayout.peekThumbnailFrame(position: 6, count: 7, in: canvas, scroll: 0)
        let scrolled = FollowLeaderLayout.peekThumbnailFrame(position: 6, count: 7, in: canvas, scroll: maxScroll)
        #expect(scrolled.minX < atRest.minX)
        // The last thumbnail lands fully on screen at the end of the scroll.
        #expect(scrolled.maxX <= canvas.width + 0.5)

        // Overscrolling in either direction is clamped, never runaway.
        let overscrolled = FollowLeaderLayout.peekThumbnailFrame(position: 6, count: 7, in: canvas, scroll: maxScroll + 500)
        #expect(abs(overscrolled.minX - scrolled.minX) < 0.5)
        let negative = FollowLeaderLayout.peekThumbnailFrame(position: 0, count: 7, in: canvas, scroll: -200)
        let start = FollowLeaderLayout.peekThumbnailFrame(position: 0, count: 7, in: canvas, scroll: 0)
        #expect(abs(negative.minX - start.minX) < 0.5)
    }

    @Test func thumbnailsNeverOverlapEachOther() {
        let a = FollowLeaderLayout.peekThumbnailFrame(position: 0, count: 7, in: canvas)
        let b = FollowLeaderLayout.peekThumbnailFrame(position: 1, count: 7, in: canvas)
        #expect(b.minX >= a.maxX)
    }

    /// Scrolling is a Peek-only concern; Hidden mode has no strip at all.
    @Test func hiddenModeIgnoresTheScrollOffset() {
        let a = FollowLeaderLayout.placement(
            isLeader: false, followerPosition: 3, followerCount: 7,
            in: canvas, style: .hidden, peekScroll: 0
        )
        let b = FollowLeaderLayout.placement(
            isLeader: false, followerPosition: 3, followerCount: 7,
            in: canvas, style: .hidden, peekScroll: 400
        )
        #expect(a == b)
    }

    // MARK: - Navigation stagger cap

    /// The replay queue's head start was capped last round; the stagger used
    /// for navigating, back, forward and reload was left uncapped, so the last
    /// window of a Slow eight-window grid waited nearly two seconds before it
    /// even started loading.
    @Test func navigationStaggerIsCappedOnABigSlowGrid() {
        let profile = SpeedProfile.slow
        let step = profile.followLeaderStaggerStep.seconds
        let cap = profile.followLeaderMaxStagger.seconds

        // Seven followers: the old maths charged step × position with no
        // ceiling at all.
        let uncappedLast = step * 7
        let cappedLast = FollowLeaderPacing.leadIn(position: 7, step: step, cap: cap)
        #expect(uncappedLast > cap)
        #expect(cappedLast == cap)
    }

    @Test func everySpeedProfileKeepsNavigationWithinItsCap() {
        for profile in SpeedProfile.allCases {
            let step = profile.followLeaderStaggerStep.seconds
            let cap = profile.followLeaderMaxStagger.seconds
            // Position 15 is the last window of a full 16-window grid.
            let lead = FollowLeaderPacing.leadIn(position: 15, step: step, cap: cap)
            #expect(lead <= cap)
            #expect(lead <= 2.0)
        }
    }

    /// The first follower still gets a real head start — the cap must not
    /// flatten the de-synchronising ripple that the stagger exists for.
    @Test func theRippleSurvivesTheCap() {
        let profile = SpeedProfile.slow
        let step = profile.followLeaderStaggerStep.seconds
        let cap = profile.followLeaderMaxStagger.seconds
        let first = FollowLeaderPacing.leadIn(position: 1, step: step, cap: cap)
        let second = FollowLeaderPacing.leadIn(position: 2, step: step, cap: cap)
        #expect(first == 0.25)
        #expect(second == 0.5)
        #expect(second > first)
    }

    @Test func turboNavigatesEveryWindowAtOnce() {
        let profile = SpeedProfile.turbo
        let lead = FollowLeaderPacing.leadIn(
            position: 15,
            step: profile.followLeaderStaggerStep.seconds,
            cap: profile.followLeaderMaxStagger.seconds
        )
        #expect(lead == 0)
    }

    // MARK: - Grid labels

    /// Eight always read "4×2" — four across, two down. Six read "2×3" while
    /// rendering three across and two down, and twelve had the same flip.
    @Test func everyGridIsLabelledAcrossByDown() {
        #expect(WindowGridSize.four.label == "2×2")
        #expect(WindowGridSize.six.label == "3×2")
        #expect(WindowGridSize.eight.label == "4×2")
        #expect(WindowGridSize.nine.label == "3×3")
        #expect(WindowGridSize.twelve.label == "4×3")
        #expect(WindowGridSize.sixteen.label == "4×4")
    }

    /// The label has to match the geometry it describes, for every size.
    @Test func labelsMatchTheActualGeometry() {
        for size in WindowGridSize.allCases {
            #expect(size.label == "\(size.columns)×\(size.rows)")
            #expect(size.rows * size.columns >= size.rawValue)
        }
    }
}

import Foundation

/// The part of a card one checkout field is asking for.
///
/// Used on the Follow the Leader path: when a rotate-mode follower is about to
/// replay the leader typing into a card field, it needs to know *which* card
/// field so it can put its own card's matching value there instead. Classifying
/// in Swift — from the descriptive hint the recorder already captures — keeps
/// the substitution testable rather than buried in injected JavaScript.
nonisolated enum CardFieldKind: String, Equatable, Sendable {
    case number
    case expiryCombined
    case expiryMonth
    case expiryYear
    case securityCode
    case cardholderName

    /// Classifies the element an action targeted.
    ///
    /// The standard `autocomplete` tokens are checked first because they are
    /// unambiguous when present; everything after that is the same
    /// name/id/placeholder/label sniffing a normal browser falls back to.
    /// Returns nil for anything that isn't clearly a card field — guessing
    /// wrong here would put a card number into a search box.
    static func classify(hint: FollowLeaderHint) -> CardFieldKind? {
        if let byToken = fromAutocomplete(hint.autocomplete) { return byToken }
        // A password box is never a card field, whatever it is called.
        if hint.type == "password" { return nil }
        if hint.tag == "select" {
            // Selects only ever stand in for the two expiry halves.
            return fromText(
                [hint.name, hint.id, hint.aria, hint.label].joined(separator: " "),
                allowNumber: false
            )
        }
        let haystack = [
            hint.name, hint.id, hint.placeholder, hint.aria, hint.label
        ].joined(separator: " ")
        return fromText(haystack, allowNumber: true)
    }

    /// Exact match against the WHATWG autofill tokens. `autocomplete` can
    /// carry section/billing prefixes ("billing cc-number"), so each token is
    /// examined on its own.
    private static func fromAutocomplete(_ raw: String) -> CardFieldKind? {
        let tokens = raw.lowercased().split(whereSeparator: \.isWhitespace)
        for token in tokens {
            switch token {
            case "cc-number": return .number
            case "cc-exp": return .expiryCombined
            case "cc-exp-month": return .expiryMonth
            case "cc-exp-year": return .expiryYear
            case "cc-csc": return .securityCode
            case "cc-name", "cc-given-name", "cc-family-name": return .cardholderName
            default: continue
            }
        }
        return nil
    }

    private static func fromText(_ raw: String, allowNumber: Bool) -> CardFieldKind? {
        let text = normalize(raw)
        guard !text.isEmpty else { return nil }

        // Security code first: "cvc" and "cvv" are unmistakable, and the
        // phrase often also contains "card", which would otherwise pull it
        // toward the number branch. Note the absence of a bare "cid": it
        // hides inside "accident", "decide" and "incident".
        if contains(text, ["cvc", "cvv", "csc", "securitycode", "cardcode", "cardverification", "verificationcode"]) {
            return .securityCode
        }

        let mentionsExpiry = contains(text, ["exp", "validthru", "validuntil", "goodthru"])
        let cardContext = contains(text, ["card", "credit", "payment"])
        let mentionsMonth = contains(text, ["month", "mm", "mon"])
        let mentionsYear = contains(text, ["year", "yy", "yr"])

        // "mm" and "mon" hide inside perfectly innocent words — "summary",
        // "money", "monitor" — and typing a card's expiry month into a
        // summary box would be a genuinely bad failure. So a month/year hint
        // only counts when the field is demonstrably about an expiry or a
        // card, or when it is the entire description of the field.
        let bareMonth = ["mm", "month"].contains(text)
        let bareYear = ["yy", "yyyy", "year"].contains(text)
        let bareCombined = ["mmyy", "mmyyyy", "monthyear"].contains(text)

        if mentionsExpiry {
            // Both halves named in one field means the site wants MM/YY in a
            // single box.
            if mentionsMonth && mentionsYear { return .expiryCombined }
            if mentionsMonth { return .expiryMonth }
            if mentionsYear { return .expiryYear }
            return .expiryCombined
        }
        if bareCombined { return .expiryCombined }
        if cardContext && mentionsMonth && mentionsYear { return .expiryCombined }
        if bareMonth || (cardContext && mentionsMonth) { return .expiryMonth }
        if bareYear || (cardContext && mentionsYear) { return .expiryYear }

        if contains(text, ["cardholder", "nameoncard", "cardname", "ccname", "holdername", "accountholder"]) {
            return .cardholderName
        }

        guard allowNumber else { return nil }
        // A bare "pan" is deliberately absent — it sits inside "company",
        // "panel" and "expander".
        if contains(text, ["cardnumber", "ccnumber", "creditcard", "cardnum", "ccnum", "acctnum"]) {
            return .number
        }
        // Bare "card" plus "number" in any order — covers `card_number`,
        // `number-card`, `numeroCarte` style naming once punctuation is gone.
        if contains(text, ["card"]) && contains(text, ["number", "num"]) { return .number }
        return nil
    }

    /// Lowercased with punctuation and whitespace stripped, so `card_number`,
    /// `card-number`, `cardNumber` and `Card Number` all reduce to the same
    /// haystack.
    private static func normalize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw.lowercased() where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        for needle in needles {
            let cleaned = needle.replacingOccurrences(of: " ", with: "")
            if !cleaned.isEmpty, haystack.contains(cleaned) { return true }
        }
        return false
    }
}

/// Rewrites a mirrored action so a follower fills its own card instead of the
/// leader's.
nonisolated enum CardSubstitution {
    /// The follower's value for one card field.
    ///
    /// - Parameter leaderValue: what the leader currently has in the box. Used
    ///   for two things only: an empty leader value means the field was
    ///   cleared, which must stay cleared, and the leader's own separator is
    ///   reused for a combined expiry so a site expecting `MM / YY` still
    ///   parses it.
    static func value(
        for kind: CardFieldKind,
        card: CardFillPayload,
        leaderValue: String
    ) -> String {
        // Clearing a field is mirrored as-is. Substituting a full number into
        // a box the user just emptied would fight them.
        guard !leaderValue.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        switch kind {
        case .number:
            return CardNumber.digits(card.secrets.number)
        case .securityCode:
            return card.secrets.securityCode
        case .cardholderName:
            return card.record.cardholderName
        case .expiryMonth:
            return card.record.monthString
        case .expiryYear:
            // Match the width the leader is using: a two-digit box must not
            // receive a four-digit year.
            let leaderDigits = CardNumber.digits(leaderValue)
            return leaderDigits.count > 2 ? card.record.fullYear : card.record.shortYear
        case .expiryCombined:
            return card.record.monthString + separator(in: leaderValue) + card.record.shortYear
        }
    }

    /// Applies the substitution to a queued action, leaving anything that is
    /// not a card input untouched.
    static func substitute(
        _ action: FollowLeaderAction,
        with card: CardFillPayload
    ) -> FollowLeaderAction {
        guard action.kind == .input || action.kind == .select,
              let kind = CardFieldKind.classify(hint: action.hint) else { return action }
        var copy = action
        copy.value = value(for: kind, card: card, leaderValue: action.value)
        return copy
    }

    /// The separator the leader typed between month and year, defaulting to a
    /// plain slash when they haven't reached one yet.
    private static func separator(in leaderValue: String) -> String {
        var out = ""
        var seenDigitAfterSeparator = false
        for character in leaderValue {
            if character.isNumber {
                if !out.isEmpty { seenDigitAfterSeparator = true }
                continue
            }
            if seenDigitAfterSeparator { break }
            out.append(character)
        }
        return out.isEmpty ? "/" : out
    }
}

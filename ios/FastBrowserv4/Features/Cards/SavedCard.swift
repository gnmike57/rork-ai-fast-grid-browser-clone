import Foundation
import SwiftData

/// A saved payment card.
///
/// Only non-secret display metadata lives in SwiftData. The full number and
/// the security code are held in the keychain under this card's `id` — the
/// same split the vault already uses for passwords, so a database file that
/// leaks never carries a usable card.
@Model
final class SavedCard {
    @Attribute(.unique) var id: String
    var cardholderName: String
    /// Last four digits. Kept in the store so the wallet, the window map and
    /// the follower chips can name a card without touching the keychain.
    var last4: String
    /// Derived from the number's prefix when the card is saved — never typed
    /// by the user.
    var brandRaw: String
    var expMonth: Int
    var expYear: Int
    /// Position in the wallet. This *is* the assignment order: window one
    /// takes the first card, window two the second, and so on down the list.
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        cardholderName: String,
        last4: String,
        brand: CardBrand,
        expMonth: Int,
        expYear: Int,
        sortOrder: Int
    ) {
        self.id = UUID().uuidString
        self.cardholderName = cardholderName
        self.last4 = last4
        self.brandRaw = brand.rawValue
        self.expMonth = expMonth
        self.expYear = expYear
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var brand: CardBrand { CardBrand(rawValue: brandRaw) ?? .unknown }

    /// Value snapshot used by the controller, the window map and the pure
    /// assignment math, so none of them hold a live model reference.
    var record: CardRecord {
        CardRecord(
            id: id,
            cardholderName: cardholderName,
            last4: last4,
            brand: brand,
            expMonth: expMonth,
            expYear: expYear
        )
    }
}

/// Card network, detected from the number's prefix. Drives the wallet icon
/// and — more usefully — the expected security-code length.
nonisolated enum CardBrand: String, CaseIterable, Sendable {
    case visa
    case mastercard
    case amex
    case discover
    case diners
    case jcb
    case unionPay
    case unknown

    var displayName: String {
        switch self {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .amex: return "Amex"
        case .discover: return "Discover"
        case .diners: return "Diners Club"
        case .jcb: return "JCB"
        case .unionPay: return "UnionPay"
        case .unknown: return "Card"
        }
    }

    /// Security codes are four digits on Amex and three everywhere else.
    var securityCodeLength: Int { self == .amex ? 4 : 3 }

    /// Digits in a complete number. Used only to hint the form, never to
    /// reject a card — plenty of valid numbers sit outside the common lengths.
    var numberLength: Int {
        switch self {
        case .amex: return 15
        case .diners: return 14
        default: return 16
        }
    }

    /// Digit grouping used when the number is displayed. Amex is 4-6-5.
    var grouping: [Int] {
        switch self {
        case .amex: return [4, 6, 5]
        case .diners: return [4, 6, 4]
        default: return [4, 4, 4, 4]
        }
    }

    /// Best-effort network from the leading digits. Deliberately prefix-only:
    /// the point is a right-looking icon and the right CVV length, not a
    /// verdict on whether the card is real.
    static func detect(from number: String) -> CardBrand {
        let digits = CardNumber.digits(number)
        guard !digits.isEmpty else { return .unknown }
        let two = Int(digits.prefix(2)) ?? 0
        let three = Int(digits.prefix(3)) ?? 0
        let four = Int(digits.prefix(4)) ?? 0

        if digits.hasPrefix("4") { return .visa }
        if (51...55).contains(two) { return .mastercard }
        if (2221...2720).contains(four) { return .mastercard }
        if two == 34 || two == 37 { return .amex }
        if digits.hasPrefix("6011") || two == 65 || (644...649).contains(three) { return .discover }
        if two == 36 || two == 38 || (300...305).contains(three) { return .diners }
        if (3528...3589).contains(four) { return .jcb }
        if two == 62 { return .unionPay }
        return .unknown
    }
}

/// Card-number helpers. Pure string math, kept out of the views so the
/// formatting and the Luhn check are pinned down by tests.
nonisolated enum CardNumber {
    /// Everything that isn't a digit stripped out — spaces, dashes, the
    /// non-breaking spaces some sites paste in.
    static func digits(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    static func last4(_ raw: String) -> String {
        String(digits(raw).suffix(4))
    }

    /// Groups a raw number for display, following the brand's own grouping.
    static func formatted(_ raw: String, brand: CardBrand? = nil) -> String {
        let d = digits(raw)
        guard !d.isEmpty else { return "" }
        let groups = (brand ?? CardBrand.detect(from: d)).grouping
        var out: [String] = []
        var cursor = d.startIndex
        for size in groups {
            guard cursor < d.endIndex else { break }
            let end = d.index(cursor, offsetBy: size, limitedBy: d.endIndex) ?? d.endIndex
            out.append(String(d[cursor..<end]))
            cursor = end
        }
        // Anything past the expected grouping still gets shown rather than
        // silently dropped.
        if cursor < d.endIndex { out.append(String(d[cursor...])) }
        return out.joined(separator: " ")
    }

    /// Masked form for the wallet: only the last four are ever readable.
    static func masked(last4: String, brand: CardBrand) -> String {
        let total = brand.numberLength
        let hiddenCount = max(0, total - 4)
        let groups = brand.grouping
        var hidden = String(repeating: "•", count: hiddenCount)
        var out: [String] = []
        for size in groups.dropLast() {
            guard !hidden.isEmpty else { break }
            let take = min(size, hidden.count)
            out.append(String(hidden.prefix(take)))
            hidden = String(hidden.dropFirst(take))
        }
        if !hidden.isEmpty { out.append(hidden) }
        out.append(last4.isEmpty ? "••••" : last4)
        return out.joined(separator: " ")
    }

    /// Standard Luhn checksum. Surfaced in the form as a soft warning — a
    /// card that fails it is still saveable, because test numbers and some
    /// regional schemes legitimately don't pass.
    static func passesLuhn(_ raw: String) -> Bool {
        let d = digits(raw)
        guard d.count >= 12 else { return false }
        var sum = 0
        var double = false
        for character in d.reversed() {
            guard var value = character.wholeNumberValue else { return false }
            if double {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            double.toggle()
        }
        return sum.isMultiple(of: 10)
    }
}

/// Non-secret snapshot of one saved card.
nonisolated struct CardRecord: Identifiable, Equatable, Sendable {
    var id: String
    var cardholderName: String
    var last4: String
    var brand: CardBrand
    var expMonth: Int
    var expYear: Int

    /// Two-digit month, zero padded.
    var monthString: String { String(format: "%02d", expMonth) }
    /// Two-digit year.
    var shortYear: String { String(format: "%02d", expYear % 100) }
    /// Four-digit year.
    var fullYear: String { expYear < 100 ? "20\(shortYear)" : "\(expYear)" }
    var expiryDisplay: String { "\(monthString)/\(shortYear)" }

    /// True once the card is past its expiry month. Shown as a warning in the
    /// wallet — never a block, since a site may still accept it.
    func isExpired(asOf date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return false }
        let cardYear = expYear < 100 ? 2000 + expYear : expYear
        if cardYear != year { return cardYear < year }
        return expMonth < month
    }
}

/// The two secret fields, read from the keychain only when a fill actually
/// needs them.
nonisolated struct CardSecrets: Codable, Equatable, Sendable {
    var number: String
    var securityCode: String
}

/// Everything one window needs to fill one card. Built at fill time and
/// handed straight to the injected script.
nonisolated struct CardFillPayload: Equatable, Sendable {
    var record: CardRecord
    var secrets: CardSecrets

    var jsArguments: [String: Any] {
        [
            "number": CardNumber.digits(secrets.number),
            "cvv": secrets.securityCode,
            "name": record.cardholderName,
            "month": record.monthString,
            "shortYear": record.shortYear,
            "fullYear": record.fullYear,
            "expiry": record.expiryDisplay
        ]
    }
}

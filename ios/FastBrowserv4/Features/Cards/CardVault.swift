import Foundation
import SwiftData
import os

/// The wallet: the ordered list of saved cards, the mode that decides how they
/// spread across windows, and the rotation offset.
///
/// One shared instance so the toolbar button, the Cards menu and the
/// multi-window controller always agree on the assignment — the window map
/// would be a lie if any of them kept its own copy.
@Observable
@MainActor
final class CardVault {
    static let shared = CardVault()
    private static let log = Logger(subsystem: "com.fastfill.browser", category: "Cards")

    private static let modeKey = "cardFillMode"
    private static let offsetKey = "cardRotationOffset"
    private static let autoFillKey = "cardAutoFillArmed"

    /// Non-secret snapshots in assignment order. Secrets are fetched from the
    /// keychain only at fill time.
    private(set) var records: [CardRecord] = []

    var mode: CardFillMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    /// How far "Next Set" has advanced the rotation.
    private(set) var rotationOffset: Int

    /// When armed, a window fills its card by itself as soon as a page with
    /// card fields finishes loading.
    var isAutoFillArmed: Bool {
        didSet {
            guard oldValue != isAutoFillArmed else { return }
            UserDefaults.standard.set(isAutoFillArmed, forKey: Self.autoFillKey)
        }
    }

    private weak var modelContext: ModelContext?

    private init() {
        let defaults = UserDefaults.standard
        mode = CardFillMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .rotate
        rotationOffset = defaults.integer(forKey: Self.offsetKey)
        isAutoFillArmed = defaults.bool(forKey: Self.autoFillKey)
    }

    var count: Int { records.count }
    var isEmpty: Bool { records.isEmpty }

    // MARK: - Loading

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        refresh()
    }

    /// Re-reads the wallet. Called after every mutation so the window map
    /// updates the moment a card is added, reordered or deleted.
    func refresh() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<SavedCard>(
            sortBy: [SortDescriptor(\SavedCard.sortOrder), SortDescriptor(\SavedCard.createdAt)]
        )
        do {
            records = try modelContext.fetch(descriptor).map(\.record)
        } catch {
            Self.log.error("wallet fetch failed: \(error.localizedDescription, privacy: .public)")
            records = []
        }
        clampOffset()
    }

    // MARK: - Assignment

    /// Card index for one position in the window order, or nil on an empty
    /// wallet.
    func cardIndex(forPosition position: Int) -> Int? {
        CardAssignment.cardIndex(
            position: position,
            cardCount: records.count,
            offset: rotationOffset,
            mode: mode
        )
    }

    /// The card one position in the window order will fill.
    func record(forPosition position: Int) -> CardRecord? {
        guard let index = cardIndex(forPosition: position), records.indices.contains(index) else { return nil }
        return records[index]
    }

    /// Advances the whole rotation by one card.
    func advanceRotation() {
        rotationOffset = CardAssignment.advanced(offset: rotationOffset, cardCount: records.count)
        UserDefaults.standard.set(rotationOffset, forKey: Self.offsetKey)
    }

    /// A wallet that shrank must not leave the offset pointing off the end.
    private func clampOffset() {
        guard !records.isEmpty else {
            if rotationOffset != 0 {
                rotationOffset = 0
                UserDefaults.standard.set(0, forKey: Self.offsetKey)
            }
            return
        }
        let clamped = ((rotationOffset % records.count) + records.count) % records.count
        if clamped != rotationOffset {
            rotationOffset = clamped
            UserDefaults.standard.set(clamped, forKey: Self.offsetKey)
        }
    }

    // MARK: - Secrets

    /// Full fill payload for a card, or nil when its secrets are missing —
    /// which happens if the keychain item was removed out from under the
    /// store. Callers treat that as "skip this window" rather than filling
    /// something half-formed.
    func payload(for record: CardRecord) -> CardFillPayload? {
        guard let secrets = CardKeychainService.shared.secrets(for: record.id) else {
            Self.log.error("no keychain secrets for card ending \(record.last4, privacy: .public)")
            return nil
        }
        return CardFillPayload(record: record, secrets: secrets)
    }

    func payload(forPosition position: Int) -> CardFillPayload? {
        guard let record = record(forPosition: position) else { return nil }
        return payload(for: record)
    }

    func secrets(for cardID: String) -> CardSecrets? {
        CardKeychainService.shared.secrets(for: cardID)
    }

    // MARK: - Mutations

    /// Creates a card and stores its secrets. Returns false if the keychain
    /// write fails, in which case nothing is persisted — a card whose number
    /// never made it would silently fill blanks forever.
    @discardableResult
    func addCard(
        cardholderName: String,
        number: String,
        securityCode: String,
        expMonth: Int,
        expYear: Int
    ) -> Bool {
        guard let modelContext else { return false }
        let digits = CardNumber.digits(number)
        guard digits.count >= 12 else { return false }
        let brand = CardBrand.detect(from: digits)
        let card = SavedCard(
            cardholderName: cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
            last4: CardNumber.last4(digits),
            brand: brand,
            expMonth: expMonth,
            expYear: expYear,
            sortOrder: (records.count)
        )
        let stored = CardKeychainService.shared.save(
            CardSecrets(number: digits, securityCode: securityCode),
            for: card.id
        )
        guard stored else {
            Self.log.error("keychain write failed — card not saved")
            return false
        }
        modelContext.insert(card)
        save()
        refresh()
        return true
    }

    @discardableResult
    func updateCard(
        _ card: SavedCard,
        cardholderName: String,
        number: String,
        securityCode: String,
        expMonth: Int,
        expYear: Int
    ) -> Bool {
        let digits = CardNumber.digits(number)
        guard digits.count >= 12 else { return false }
        let stored = CardKeychainService.shared.save(
            CardSecrets(number: digits, securityCode: securityCode),
            for: card.id
        )
        guard stored else { return false }
        card.cardholderName = cardholderName.trimmingCharacters(in: .whitespacesAndNewlines)
        card.last4 = CardNumber.last4(digits)
        card.brandRaw = CardBrand.detect(from: digits).rawValue
        card.expMonth = expMonth
        card.expYear = expYear
        card.updatedAt = Date()
        save()
        refresh()
        return true
    }

    func deleteCard(_ card: SavedCard) {
        guard let modelContext else { return }
        CardKeychainService.shared.delete(for: card.id)
        modelContext.delete(card)
        save()
        resequence()
        refresh()
    }

    /// Duplicates a card, secrets included, and drops the copy directly after
    /// the original so the rotation order stays predictable.
    @discardableResult
    func duplicate(_ card: SavedCard) -> Bool {
        guard let modelContext, let secrets = CardKeychainService.shared.secrets(for: card.id) else { return false }
        let copy = SavedCard(
            cardholderName: card.cardholderName,
            last4: card.last4,
            brand: card.brand,
            expMonth: card.expMonth,
            expYear: card.expYear,
            sortOrder: card.sortOrder + 1
        )
        guard CardKeychainService.shared.save(secrets, for: copy.id) else { return false }
        for existing in fetchAll() where existing.sortOrder > card.sortOrder {
            existing.sortOrder += 1
        }
        modelContext.insert(copy)
        save()
        refresh()
        return true
    }

    /// Applies a drag-reorder from the wallet list. `ordered` is the new
    /// full order.
    func applyOrder(_ ordered: [SavedCard]) {
        for (position, card) in ordered.enumerated() {
            if card.sortOrder != position { card.sortOrder = position }
        }
        save()
        refresh()
    }

    private func fetchAll() -> [SavedCard] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<SavedCard>(
            sortBy: [SortDescriptor(\SavedCard.sortOrder), SortDescriptor(\SavedCard.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Closes gaps left by a delete so `sortOrder` stays 0..<n.
    private func resequence() {
        for (position, card) in fetchAll().enumerated() where card.sortOrder != position {
            card.sortOrder = position
        }
        save()
    }

    private func save() {
        guard let modelContext else { return }
        do {
            try modelContext.save()
        } catch {
            Self.log.error("wallet save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

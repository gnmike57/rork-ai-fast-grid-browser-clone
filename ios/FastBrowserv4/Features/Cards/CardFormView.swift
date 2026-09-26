import SwiftUI
import SwiftData

/// Add or edit one card. Four fields, nothing more.
struct CardFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Nil when adding.
    let card: SavedCard?

    private let vault = CardVault.shared
    @State private var cardholderName: String = ""
    @State private var numberText: String = ""
    @State private var expiryText: String = ""
    @State private var securityCode: String = ""
    @State private var isSecurityCodeVisible: Bool = false
    @State private var errorMessage: String?
    @State private var hasLoaded: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, number, expiry, code
    }

    private var brand: CardBrand { CardBrand.detect(from: numberText) }

    private var digitCount: Int { CardNumber.digits(numberText).count }

    /// Parsed expiry, or nil while it is still incomplete or nonsensical.
    private var parsedExpiry: (month: Int, year: Int)? {
        let digits = CardNumber.digits(expiryText)
        guard digits.count >= 3 else { return nil }
        guard let month = Int(digits.prefix(2)), (1...12).contains(month) else { return nil }
        let yearPart = String(digits.dropFirst(2))
        guard let rawYear = Int(yearPart), !yearPart.isEmpty else { return nil }
        let year = yearPart.count <= 2 ? 2000 + rawYear : rawYear
        guard (2000...2100).contains(year) else { return nil }
        return (month, year)
    }

    private var canSave: Bool {
        digitCount >= 12 && parsedExpiry != nil && !securityCode.isEmpty
    }

    var body: some View {
        Form {
            Section {
                cardPreview
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField("Cardholder name", text: $cardholderName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .name)

                TextField("Card number", text: $numberText)
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .number)
                    .onChange(of: numberText) { _, newValue in
                        let formatted = CardNumber.formatted(newValue)
                        if formatted != newValue { numberText = formatted }
                    }

                HStack {
                    TextField("MM/YY", text: $expiryText)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .expiry)
                        .onChange(of: expiryText) { _, newValue in
                            let formatted = Self.formatExpiry(newValue)
                            if formatted != newValue { expiryText = formatted }
                        }

                    Divider()

                    HStack {
                        if isSecurityCodeVisible {
                            TextField(codePlaceholder, text: $securityCode)
                                .keyboardType(.numberPad)
                                .font(.system(.body, design: .monospaced))
                                .focused($focusedField, equals: .code)
                        } else {
                            SecureField(codePlaceholder, text: $securityCode)
                                .font(.system(.body, design: .monospaced))
                                .focused($focusedField, equals: .code)
                        }
                        Button {
                            isSecurityCodeVisible.toggle()
                        } label: {
                            Image(systemName: isSecurityCodeVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSecurityCodeVisible ? "Hide security code" : "Show security code")
                    }
                    .onChange(of: securityCode) { _, newValue in
                        let trimmed = String(CardNumber.digits(newValue).prefix(4))
                        if trimmed != newValue { securityCode = trimmed }
                    }
                }
            } header: {
                Text("Card")
            } footer: {
                validationFooter
            }
        }
        .navigationTitle(card == nil ? "Add Card" : "Edit Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
            }
        }
        .task { load() }
        .alert("Couldn't save", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var codePlaceholder: String {
        brand == .amex ? "CID" : "CVV"
    }

    private var cardPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .font(.title3)
                Spacer()
                Text(brand.displayName.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .kerning(1)
            }
            Text(numberText.isEmpty
                 ? CardNumber.masked(last4: "", brand: brand)
                 : CardNumber.formatted(numberText, brand: brand))
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack {
                Text(cardholderName.isEmpty ? "CARDHOLDER" : cardholderName.uppercased())
                    .lineLimit(1)
                Spacer()
                Text(expiryText.isEmpty ? "MM/YY" : expiryText)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    .linearGradient(
                        colors: [Color.cardGold.opacity(0.95), Color(red: 0.42, green: 0.30, blue: 0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.16))
        )
    }

    @ViewBuilder
    private var validationFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if digitCount > 0 && digitCount < 12 {
                Label("Card number looks too short.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else if digitCount >= 12 && !CardNumber.passesLuhn(numberText) {
                // A soft warning only: test numbers and some regional schemes
                // legitimately fail the checksum, and refusing to save them
                // would be worse than letting the site decide.
                Label("This number fails the usual checksum — saving anyway is fine.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if !expiryText.isEmpty && parsedExpiry == nil {
                Label("Expiry needs a month 01–12 and a year.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if !securityCode.isEmpty && securityCode.count != brand.securityCodeLength {
                Label(
                    "\(brand.displayName) codes are usually \(brand.securityCodeLength) digits.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    // MARK: - Formatting

    /// Keeps the expiry box reading MM/YY as it is typed, without fighting a
    /// backspace over the slash.
    static func formatExpiry(_ raw: String) -> String {
        let digits = String(CardNumber.digits(raw).prefix(4))
        guard !digits.isEmpty else { return "" }
        if digits.count <= 2 {
            // A lone digit above 1 can only be a month like 9 → 09.
            if digits.count == 1, let value = Int(digits), value > 1 {
                return "0\(digits)/"
            }
            return digits
        }
        let month = String(digits.prefix(2))
        let year = String(digits.dropFirst(2))
        return "\(month)/\(year)"
    }

    // MARK: - Load / save

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        vault.attach(modelContext: modelContext)
        guard let card else { return }
        cardholderName = card.cardholderName
        expiryText = "\(card.record.monthString)/\(card.record.shortYear)"
        if let secrets = vault.secrets(for: card.id) {
            numberText = CardNumber.formatted(secrets.number, brand: card.brand)
            securityCode = secrets.securityCode
        } else {
            errorMessage = "This card's number couldn't be read from the keychain. Re-enter it to fix the card."
        }
    }

    private func save() {
        guard let expiry = parsedExpiry else { return }
        let succeeded: Bool
        if let card {
            succeeded = vault.updateCard(
                card,
                cardholderName: cardholderName,
                number: numberText,
                securityCode: securityCode,
                expMonth: expiry.month,
                expYear: expiry.year
            )
        } else {
            succeeded = vault.addCard(
                cardholderName: cardholderName,
                number: numberText,
                securityCode: securityCode,
                expMonth: expiry.month,
                expYear: expiry.year
            )
        }
        if succeeded {
            dismiss()
        } else {
            errorMessage = "The card couldn't be written to the keychain, so nothing was saved."
        }
    }
}

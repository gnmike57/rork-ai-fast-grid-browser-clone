import SwiftUI

struct PasswordGeneratorView: View {
    var onSelect: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var generatedPassword: String = ""
    @State private var length: Double = 20
    @State private var includeUppercase: Bool = true
    @State private var includeLowercase: Bool = true
    @State private var includeNumbers: Bool = true
    @State private var includeSymbols: Bool = true
    @State private var copyFeedback: Int = 0

    private var strength: PasswordStrength {
        PasswordGeneratorService.calculateStrength(generatedPassword)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Text(generatedPassword.isEmpty ? "Tap Generate" : generatedPassword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(.rect(cornerRadius: 8))

                    if !generatedPassword.isEmpty {
                        HStack {
                            strengthIndicator

                            Spacer()

                            Button("Copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = generatedPassword
                                copyFeedback += 1
                            }
                            .font(.subheadline)
                            .sensoryFeedback(.success, trigger: copyFeedback)
                        }
                    }
                }
            }

            Section("Options") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Length: \(Int(length))")
                        .font(.subheadline)
                    Slider(value: $length, in: 8...64, step: 1)
                }

                Toggle("Uppercase (A-Z)", isOn: $includeUppercase)
                Toggle("Lowercase (a-z)", isOn: $includeLowercase)
                Toggle("Numbers (0-9)", isOn: $includeNumbers)
                Toggle("Symbols (!@#$)", isOn: $includeSymbols)
            }

            Section {
                Button {
                    withAnimation(.snappy) {
                        generatedPassword = PasswordGeneratorService.generate(
                            length: Int(length),
                            includeUppercase: includeUppercase,
                            includeLowercase: includeLowercase,
                            includeNumbers: includeNumbers,
                            includeSymbols: includeSymbols
                        )
                    }
                } label: {
                    Label("Generate Password", systemImage: "dice.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Password Generator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            if onSelect != nil && !generatedPassword.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        onSelect?(generatedPassword)
                        dismiss()
                    }
                }
            }
        }
        .task {
            generatedPassword = PasswordGeneratorService.generate(length: Int(length))
        }
    }

    private var strengthIndicator: some View {
        HStack(spacing: 6) {
            let bars = strengthBars
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < bars.filled ? bars.color : Color(.quaternaryLabel))
                    .frame(width: 24, height: 4)
            }
            Text(strength.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var strengthBars: (filled: Int, color: Color) {
        switch strength {
        case .empty: return (0, .gray)
        case .weak: return (1, .red)
        case .medium: return (2, .orange)
        case .strong: return (3, .green)
        }
    }
}

import Foundation

struct PasswordGeneratorService {
    static func generate(
        length: Int = 20,
        includeUppercase: Bool = true,
        includeLowercase: Bool = true,
        includeNumbers: Bool = true,
        includeSymbols: Bool = true
    ) -> String {
        var chars = ""
        if includeUppercase { chars += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        if includeLowercase { chars += "abcdefghijklmnopqrstuvwxyz" }
        if includeNumbers { chars += "0123456789" }
        if includeSymbols { chars += "!@#$%^&*()-_=+[]{}|;:,.<>?" }

        guard !chars.isEmpty else { return "" }

        let charArray = Array(chars)
        var password = ""

        // Fill the byte buffer from the system CSPRNG. Retry on failure — a
        // zeroed buffer would silently collapse to one repeated character,
        // which is a catastrophically weak password.
        var randomBytes = [UInt8](repeating: 0, count: length)
        var generated = false
        for _ in 0..<3 where !generated {
            generated = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes) == errSecSuccess
        }
        guard generated else { return "" }

        for i in 0..<length {
            // Unbiased index: scale the byte into [0, count) without modulo.
            let index = Int(UInt32(randomBytes[i]) * UInt32(charArray.count) / 256)
            password.append(charArray[index])
        }

        return password
    }

    static func calculateStrength(_ password: String) -> PasswordStrength {
        let length = password.count
        if length == 0 { return .empty }
        if length < 8 { return .weak }

        var score = 0
        if length >= 12 { score += 1 }
        if length >= 16 { score += 1 }
        if password.range(of: "[A-Z]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[a-z]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[0-9]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil { score += 1 }

        if score <= 2 { return .weak }
        if score <= 4 { return .medium }
        return .strong
    }
}

enum PasswordStrength: String {
    case empty = ""
    case weak = "Weak"
    case medium = "Medium"
    case strong = "Strong"

    var color: String {
        switch self {
        case .empty: return "secondary"
        case .weak: return "red"
        case .medium: return "orange"
        case .strong: return "green"
        }
    }
}

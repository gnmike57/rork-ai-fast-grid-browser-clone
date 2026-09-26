import Foundation
import SwiftData
import UniformTypeIdentifiers

nonisolated struct ImportedCredential: Sendable {
    let domain: String
    let username: String
    /// One or more passwords for this credential. The first entry is the
    /// primary password used by single-shot autofill; RCR will try the rest
    /// in order if the primary is rejected.
    let passwords: [String]
    let notes: String?

    /// Convenience accessor for legacy single-password code paths.
    var password: String { passwords.first ?? "" }
}

nonisolated enum ImportFormat: String, CaseIterable, Sendable {
    case chromeCSV = "Chrome CSV"
    case firefoxCSV = "Firefox CSV"
    case genericCSV = "Generic CSV"
    case multiPasswordCSV = "Multi-Password CSV"
    case comboList = "Combo List"

    var description: String {
        switch self {
        case .chromeCSV: return "Export from Chrome: Settings → Passwords → Export"
        case .firefoxCSV: return "Export from Firefox: Settings → Logins → Export"
        case .genericCSV: return "CSV with columns: url, username, password"
        case .multiPasswordCSV:
            return "CSV with: email, password1, password2, … — multiple passwords per email on the same row."
        case .comboList:
            return "Plain text combo list: login:password (or login;password, login,password). One per line."
        }
    }
}

/// Separator between login and password in a combo list line.
nonisolated enum ComboListSeparator: String, CaseIterable, Sendable {
    case auto = "Auto"
    case colon = ":"
    case semicolon = ";"
    case comma = ","

    var character: Character? {
        switch self {
        case .auto: return nil
        case .colon: return ":"
        case .semicolon: return ";"
        case .comma: return ","
        }
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .colon: return ": Colon"
        case .semicolon: return "; Semicolon"
        case .comma: return ", Comma"
        }
    }
}

/// Whether the first part of each combo line is an email or a plain username.
nonisolated enum ComboListFormat: String, CaseIterable, Sendable {
    case email = "Email"
    case username = "Username"
}

/// Lightweight preview counts shown before the user confirms an import.
nonisolated struct ComboListPreview: Sendable {
    let credentialCount: Int
    let passwordCount: Int
    let skippedCount: Int
    let mergedCount: Int

    var isEmpty: Bool { credentialCount == 0 }
}

/// Pure text parsers for importing credentials — no state, so safe to run
/// off the main thread for large files.
nonisolated struct CredentialImportService {
    static func parseCSV(_ content: String, format: ImportFormat) -> [ImportedCredential] {
        if format == .multiPasswordCSV {
            return parseMultiPasswordCSV(content)
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }

        var results: [ImportedCredential] = []

        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 3 else { continue }

            let (urlField, userField, passField) = fieldIndices(for: format, fields: fields)
            guard let url = urlField, let user = userField, let pass = passField else { continue }
            guard !user.isEmpty, !pass.isEmpty else { continue }

            let domain = extractDomain(from: url)
            guard !domain.isEmpty else { continue }

            results.append(ImportedCredential(
                domain: domain,
                username: user,
                passwords: [pass],
                notes: nil
            ))
        }

        return results
    }

    /// Parse the wide "email, password1, password2, …" format. The first
    /// column is the email (also used as the username); every remaining
    /// non-empty column on the row is a saved password for that email.
    /// The credential's `domain` is taken from the email's domain part so
    /// the vault still groups by provider, but RCR treats credentials as
    /// global so this only affects vault grouping/sort.
    static func parseMultiPasswordCSV(_ content: String) -> [ImportedCredential] {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        // Detect header: if the first column is literally "email" we drop
        // the first row. Otherwise treat every row as data.
        let firstFields = parseCSVLine(lines[0])
        let dataLines: ArraySlice<String>
        if let first = firstFields.first?.lowercased(), first == "email" || first == "username" {
            dataLines = lines.dropFirst()
        } else {
            dataLines = lines[lines.indices]
        }

        // Coalesce duplicate emails: if the same email appears on multiple
        // rows, merge their passwords into one credential (deduped, order
        // preserved).
        var orderedEmails: [String] = []
        var bucket: [String: [String]] = [:]

        for line in dataLines {
            let fields = parseCSVLine(line)
            guard let emailRaw = fields.first else { continue }
            let email = emailRaw.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty, email.contains("@") else { continue }

            let passwords = fields.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if bucket[email] == nil {
                orderedEmails.append(email)
                bucket[email] = []
            }
            for pass in passwords where !(bucket[email]?.contains(pass) ?? false) {
                bucket[email, default: []].append(pass)
            }
        }

        return orderedEmails.compactMap { email in
            let passwords = bucket[email] ?? []
            guard !passwords.isEmpty else { return nil }
            let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
            guard !domain.isEmpty else { return nil }
            return ImportedCredential(
                domain: domain,
                username: email,
                passwords: passwords,
                notes: nil
            )
        }
    }

    private static func fieldIndices(
        for format: ImportFormat,
        fields: [String]
    ) -> (String?, String?, String?) {
        switch format {
        case .chromeCSV:
            guard fields.count >= 4 else { return (nil, nil, nil) }
            return (fields[1], fields[2], fields[3])
        case .firefoxCSV:
            guard fields.count >= 3 else { return (nil, nil, nil) }
            return (fields[0], fields[1], fields[2])
        case .genericCSV:
            return (fields[0], fields[1], fields[2])
        case .multiPasswordCSV, .comboList:
            return (nil, nil, nil) // handled by dedicated parsers
        }
    }

    static func extractDomain(from urlString: String) -> String {
        return ExcludedDomain.canonicalize(urlString)
    }

    /// Merges two password lists into one, preserving order and dropping
    /// duplicates. Used when an import targets a credential that already
    /// exists, so the new passwords are appended to the existing keychain
    /// entry instead of splitting the vault row from its payload.
    static func mergePasswords(existing: [String], new: [String]) -> [String] {
        var merged = existing
        for pass in new where !merged.contains(pass) {
            merged.append(pass)
        }
        return merged
    }

    // MARK: - Combo List Parsing

    /// Auto-detect the most common separator across all non-empty lines.
    /// Ties are broken in favour of colon > semicolon > comma (the most
    /// common real-world ordering for combo lists).
    static func detectSeparator(in content: String) -> ComboListSeparator {
        let lines = content
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var colonHits = 0
        var semicolonHits = 0
        var commaHits = 0
        for line in lines {
            if line.contains(":") { colonHits += 1 }
            if line.contains(";") { semicolonHits += 1 }
            if line.contains(",") { commaHits += 1 }
        }

        let maxHits = max(colonHits, max(semicolonHits, commaHits))
        guard maxHits > 0 else { return .colon }
        if colonHits == maxHits { return .colon }
        if semicolonHits == maxHits { return .semicolon }
        return .comma
    }

    /// Parse a pasted or file-loaded combo list into `ImportedCredential`s.
    ///
    /// - Each non-empty line is split into `login ‹separator› password`.
    /// - If a line has more than two fields, every field after the first is
    ///   treated as an additional password for that login (same behaviour as
    ///   the multi-password CSV).
    /// - Duplicate logins merge their passwords (deduped, order preserved).
    /// - In **email** mode lines without `@` are skipped. In **username** mode
    ///   every non-empty login is accepted; emails are still grouped by their
    ///   domain, plain usernames are grouped under `"imported"`.
    /// - The domain only affects vault grouping — RCR treats every credential
    ///   as globally testable, so this never restricts where a credential can
    ///   be used.
    static func parseComboList(
        _ content: String,
        separator: ComboListSeparator,
        format: ComboListFormat
    ) -> [ImportedCredential] {
        let resolvedSep = separator == .auto
            ? detectSeparator(in: content)
            : separator
        guard let sepChar = resolvedSep.character else { return [] }

        let lines = content.components(separatedBy: .newlines)
        var orderedLogins: [String] = []
        var bucket: [String: [String]] = [:]
        var domainForLogin: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let fields = trimmed.components(separatedBy: String(sepChar))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let login = fields.first, fields.count >= 2 else { continue }

            let passwords = Array(fields.dropFirst())

            // In email mode, skip lines that don't look like emails.
            if format == .email, !login.contains("@") { continue }

            let domain: String
            if let atIndex = login.firstIndex(of: "@") {
                domain = String(login[login.index(after: atIndex)...]).lowercased()
            } else {
                domain = "imported"
            }
            guard !domain.isEmpty else { continue }

            if bucket[login] == nil {
                orderedLogins.append(login)
                bucket[login] = []
                domainForLogin[login] = domain
            }
            for pass in passwords where !(bucket[login]?.contains(pass) ?? false) {
                bucket[login, default: []].append(pass)
            }
        }

        return orderedLogins.compactMap { login in
            let passwords = bucket[login] ?? []
            guard !passwords.isEmpty else { return nil }
            return ImportedCredential(
                domain: domainForLogin[login] ?? "imported",
                username: login,
                passwords: passwords,
                notes: nil
            )
        }
    }

    /// Build a preview without committing — used by the live counter in the
    /// Paste tab so the user sees how many credentials / passwords / skipped
    /// lines they have before tapping Import.
    static func comboListPreview(
        _ content: String,
        separator: ComboListSeparator,
        format: ComboListFormat
    ) -> ComboListPreview {
        let resolvedSep = separator == .auto
            ? detectSeparator(in: content)
            : separator
        guard let sepChar = resolvedSep.character else {
            return ComboListPreview(credentialCount: 0, passwordCount: 0, skippedCount: 0, mergedCount: 0)
        }

        let lines = content.components(separatedBy: .newlines)
        var seenLogins: [String: [String]] = [:]
        var orderedCount = 0
        var totalPasswords = 0
        var skipped = 0
        var merged = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let fields = trimmed.components(separatedBy: String(sepChar))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let login = fields.first, fields.count >= 2 else {
                skipped += 1
                continue
            }

            if format == .email, !login.contains("@") {
                skipped += 1
                continue
            }

            let passwords = Array(fields.dropFirst())
            if seenLogins[login] == nil {
                seenLogins[login] = []
                orderedCount += 1
            }
            for pass in passwords {
                if !(seenLogins[login]?.contains(pass) ?? false) {
                    seenLogins[login, default: []].append(pass)
                    totalPasswords += 1
                } else {
                    merged += 1
                }
            }
        }

        return ComboListPreview(
            credentialCount: orderedCount,
            passwordCount: totalPasswords,
            skippedCount: skipped,
            mergedCount: merged
        )
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))

        return fields
    }
}

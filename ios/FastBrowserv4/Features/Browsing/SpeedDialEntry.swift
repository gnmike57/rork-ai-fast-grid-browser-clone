import Foundation

/// A single speed-dial shortcut shown on the browser home page.
nonisolated struct SpeedDialEntry: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String
    var urlString: String

    init(id: String = UUID().uuidString, title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }

    /// A normalized URL, defaulting to `https://` when no scheme is present.
    var resolvedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://\(trimmed)")
    }

    /// Hostname used for the tile subtitle (strips scheme + leading `www.`).
    var displayHost: String {
        let host = resolvedURL?.host(percentEncoded: false)
            ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// A short monogram for the tile badge (first letter of the title/host).
    var monogram: String {
        let source = title.trimmingCharacters(in: .whitespaces).isEmpty ? displayHost : title
        return String(source.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

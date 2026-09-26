import Foundation
import Observation
import SwiftUI

/// Persisted, observable list of speed-dial shortcuts shown on the browser
/// home page. Backed by `UserDefaults` (JSON) so it survives launches and can
/// be freely edited by the user. Access through `SpeedDialStore.shared`.
@Observable
@MainActor
final class SpeedDialStore {
    static let shared = SpeedDialStore()

    private static let storageKey = "speedDialEntriesV1"
    private static let joeFortuneLoginURL = "https://joefortune.win/login"
    private static let ignitionLoginURL = "https://www.ignitioncasino.ooo/login"

    /// The default shortcuts every fresh install starts with.
    static let defaults: [SpeedDialEntry] = [
        SpeedDialEntry(title: "Google", urlString: "https://google.com"),
        SpeedDialEntry(title: "Joe Fortune", urlString: joeFortuneLoginURL),
        SpeedDialEntry(title: "Ignition", urlString: ignitionLoginURL),
        SpeedDialEntry(title: "Cafe Casino", urlString: "https://www.cafecasino.lv"),
        SpeedDialEntry(title: "Messaging Co", urlString: "https://themessagingco.com.au")
    ]

    var entries: [SpeedDialEntry] {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SpeedDialEntry].self, from: data) {
            entries = Self.migratingLegacyDefaults(in: decoded)
            if entries != decoded {
                persist()
            }
        } else {
            entries = Self.defaults
        }
    }

    /// Updates only recognized legacy built-in shortcuts. User-created and
    /// user-edited destinations are left untouched.
    private static func migratingLegacyDefaults(in entries: [SpeedDialEntry]) -> [SpeedDialEntry] {
        entries.map { entry in
            let normalizedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedURL = entry.urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var migrated = entry

            if normalizedTitle == "joe fortune", legacyJoeFortuneURLs.contains(normalizedURL) {
                migrated.urlString = joeFortuneLoginURL
            } else if normalizedTitle == "ignition", legacyIgnitionURLs.contains(normalizedURL) {
                migrated.urlString = ignitionLoginURL
            }
            return migrated
        }
    }

    private static let legacyJoeFortuneURLs: Set<String> = [
        "https://www.joefortune.fun",
        "https://www.joefortune.fun/",
        "https://joefortune.fun",
        "https://joefortune.fun/",
        "https://www.joefortune.win",
        "https://www.joefortune.win/",
        "https://joefortune.win",
        "https://joefortune.win/",
        "https://www.joefortune.win/login"
    ]

    private static let legacyIgnitionURLs: Set<String> = [
        "https://www.ignitioncasino.ooo",
        "https://www.ignitioncasino.ooo/",
        "https://ignitioncasino.ooo",
        "https://ignitioncasino.ooo/",
        "https://ignitioncasino.ooo/login"
    ]

    /// Appends a blank shortcut for the user to fill in.
    func addEntry() {
        entries.append(SpeedDialEntry(title: "", urlString: ""))
    }

    func removeEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Restores the built-in default shortcuts.
    func resetToDefaults() {
        entries = Self.defaults
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

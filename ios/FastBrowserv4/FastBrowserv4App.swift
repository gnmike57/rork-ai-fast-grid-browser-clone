import SwiftUI
import SwiftData

@main
struct FastBrowserv4App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Credential.self,
            SiteSetting.self,
            BrowsingHistoryEntry.self,
            Bookmark.self,
            ExcludedDomain.self,
            AttemptRecord.self,
            AIProviderConfig.self,
            AIRepairEvent.self,
            ParkedSession.self,
            SavedCard.self
        ])
    }
}

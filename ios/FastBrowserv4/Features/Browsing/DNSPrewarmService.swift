import Foundation
import SwiftData

@MainActor
final class DNSPrewarmService {
    static let shared = DNSPrewarmService()
    private init() {}

    func prewarmTopDomains(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<BrowsingHistoryEntry>(
            sortBy: [SortDescriptor(\BrowsingHistoryEntry.visitedAt, order: .reverse)]
        )
        guard let entries = try? modelContext.fetch(descriptor) else { return }

        var domainCounts: [String: Int] = [:]
        for entry in entries {
            guard !entry.domain.isEmpty else { continue }
            domainCounts[entry.domain, default: 0] += 1
        }

        let topDomains = domainCounts.sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }

        for domain in topDomains {
            guard let url = URL(string: "https://\(domain)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3
            let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
            task.priority = URLSessionTask.lowPriority
            task.resume()
        }
    }
}

import SwiftUI
import SwiftData

struct BookmarksView: View {
    let viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]

    var body: some View {
        List {
            ForEach(bookmarks) { bookmark in
                Button {
                    viewModel.navigateTo(bookmark.url)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bookmark.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(bookmark.domain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) {
                        modelContext.delete(bookmark)
                    }
                }
            }
        }
        .overlay {
            if bookmarks.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark", description: Text("Bookmarked pages will appear here"))
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
    }
}

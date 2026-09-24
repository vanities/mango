import SwiftUI
import ShelfKit

struct ReadingInsightsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var history = false
    @State private var estimates = false

    private var insights: ActivityInsights {
        let dates = library.visibleComics.compactMap { comic -> Date? in
            guard let p = library.progress(for: comic), p.finished else { return nil }
            return p.updatedAt
        } + library.state.readingLog.map(\.finishedAt)
        return ActivityInsights(days: library.allDayActivity, sessions: library.state.sessions, finishes: dates)
    }

    var body: some View {
        StatCard("Your reading") {
            ActivityInsightsView(insights: insights, noun: "books")
            Divider()
            let novelTime = library.state.sessions.filter(\.isNovel).reduce(0) { $0 + $1.activeSeconds }
            LabeledContent("Novel reading · this device", value: Durations.short(novelTime))
                .font(.subheadline)
            DisclosureGroup("Finish estimates", isExpanded: $estimates) {
                if let pace = library.activityStats.pagesPerMinute, pace > 0 {
                    ForEach(library.visibleComics.filter { !$0.isNovel && library.progress(for: $0)?.isStarted == true && library.progress(for: $0)?.finished != true }.prefix(5)) { comic in
                        if let p = library.progress(for: comic), p.pageCount > p.page {
                            let seconds = Double(p.pageCount - p.page) / pace * 60
                            VStack(alignment: .leading, spacing: 3) {
                                Text(comic.title).font(.subheadline)
                                Text("About \(Durations.short(seconds)) left").font(.caption).foregroundStyle(.secondary)
                                if let days = insights.daysToFinish(remainingSeconds: seconds) {
                                    Text("Roughly \(days) days at your recent pace").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                    Text("Rough estimates from your comic reading pace and the last 28 calendar days. Novel chapter estimates appear in the reader.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Read a few comic pages to build a pace estimate.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Session history", systemImage: "clock.arrow.circlepath") { history = true }
        }
        .sheet(isPresented: $history) { ReadingSessionHistory() }
    }
}

private struct ReadingSessionHistory: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var reading: Comic?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.state.sessions.sorted { $0.startedAt > $1.startedAt }) { session in
                        let comic = library.comic(id: session.comicID)
                        Button { reading = comic } label: {
                            ActivitySessionRow(title: comic?.title ?? session.seriesName, date: session.startedAt,
                                               seconds: session.activeSeconds,
                                               detail: session.isNovel ? "Novel" : "\(session.pagesTurned) pages advanced")
                        }.disabled(comic == nil)
                    }
                } footer: { Text("Sessions from this device. Open a book to resume at its current saved position.") }
            }
            .overlay { if library.state.sessions.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "clock") } }
            .navigationTitle("Session history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $reading) { ReaderRouter(comic: $0) }
        }
    }
}

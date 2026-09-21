import Charts
import SwiftUI

/// What you've actually read, built from the library and your reading positions. Mango
/// records nothing extra to produce this — there is no analytics, here or anywhere else.
struct StatsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var logging = false

    private var stats: ReadingStats { library.stats }

    var body: some View {
        NavigationStack {
            Group {
                if stats.isEmpty {
                    ContentUnavailableView("Nothing to count yet", systemImage: "chart.bar",
                                           description: Text("Add some comics in Sources and this fills in."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            headline
                            if stats.hasReadAnything { monthsChart }
                            breakdown
                            if stats.ratedCount > 0 { ratingsCard }
                            if !stats.topSeries.isEmpty { topSeriesCard }
                            loggedCard
                            storageCard
                            footnote
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { logging = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Log a book read elsewhere")
                }
            }
            .sheet(isPresented: $logging) { LogBookView() }
        }
    }

    // MARK: Ratings and the log

    private var ratingsCard: some View {
        card("Ratings") {
            if let average = stats.averageRating {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(average, format: .number.precision(.fractionLength(1)))
                        .font(.title.weight(.semibold)).monospacedDigit()
                    Text("average across \(stats.ratedCount) rated")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(Array(stats.ratingCounts.enumerated()), id: \.offset) { index, count in
                    BarMark(x: .value("Books", count), y: .value("Stars", "\(index + 1)★"))
                        .foregroundStyle(Color.yellow.gradient)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            if count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
                        }
                }
            }
            .chartYScale(domain: ["5★", "4★", "3★", "2★", "1★"])
            .chartXAxis(.hidden)
            .frame(height: 150)
        }
    }

    @ViewBuilder
    private var loggedCard: some View {
        card("Read elsewhere") {
            if library.state.readingLog.isEmpty {
                Text("Books you finished before Mango, or outside it, can be logged here so they count.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(library.state.readingLog.prefix(8)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline).lineLimit(1)
                            Text(entry.finishedAt, format: .dateTime.year().month().day())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let rating = entry.rating { StarsView(rating: rating) }
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) { library.removeLogEntry(entry) }
                    }
                }
            }
            Button { logging = true } label: {
                Label("Log a book", systemImage: "plus.circle")
            }
            .padding(.top, 2)
        }
    }

    // MARK: Headline

    private var headline: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            tile("\(stats.finishedVolumes)", "Volumes finished", "checkmark.circle.fill", .green)
            tile(stats.pagesRead.formatted(), "Pages read", "doc.text.fill", .accentColor)
            tile("\(stats.finishedSeries)", "Series completed", "books.vertical.fill", .purple)
            tile("\(stats.thisYear)", "Finished this year", "calendar", .orange)
        }
    }

    private func tile(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }

    // MARK: Charts

    private var monthsChart: some View {
        card("Finished per month") {
            Chart(stats.months) { month in
                BarMark(
                    x: .value("Month", month.label),
                    y: .value("Finished", month.finished)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 170)
            if let best = stats.bestMonth {
                Text("Best month: \(best.label), \(best.finished) finished")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var breakdown: some View {
        VStack(spacing: 12) {
            card("Library") {
                Chart {
                    SectorMark(angle: .value("Finished", stats.finishedVolumes), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(by: .value("State", "Finished"))
                    SectorMark(angle: .value("Reading", stats.inProgressVolumes), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(by: .value("State", "Reading"))
                    SectorMark(angle: .value("Unread", stats.unreadVolumes), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(by: .value("State", "Unread"))
                }
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 180)
            }
            card("By format") {
                Chart(stats.byFormat) { bucket in
                    BarMark(
                        x: .value("Count", bucket.count),
                        y: .value("Format", bucket.name)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text("\(bucket.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(max(1, stats.byFormat.count)) * 42 + 20)
            }
        }
    }

    private var topSeriesCard: some View {
        card("Most read") {
            ForEach(stats.topSeries) { bucket in
                HStack {
                    Text(bucket.name).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(bucket.count)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if bucket.id != stats.topSeries.last?.id { Divider() }
            }
        }
    }

    private var storageCard: some View {
        card("Where it lives") {
            HStack(spacing: 16) {
                storageStat("On device", stats.localBytes, "iphone")
                storageStat("On the NAS", stats.remoteBytes, "externaldrive.connected.to.line.below")
            }
            if !stats.byMedium.isEmpty {
                Divider()
                HStack(spacing: 16) {
                    ForEach(stats.byMedium) { bucket in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(bucket.count)").font(.headline).monospacedDigit()
                            Text(bucket.name).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func storageStat(_ label: String, _ bytes: Int64, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(Formatting.bytes(bytes), systemImage: icon)
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footnote: some View {
        Text("Worked out from your library and where you've got to in it. Mango collects no analytics and sends nothing anywhere — a volume's finish date is simply the last time its position changed.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }
}

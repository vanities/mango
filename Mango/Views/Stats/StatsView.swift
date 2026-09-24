import Charts
import SwiftUI
import ShelfKit

/// What you've actually read, built from the library and your reading positions. Mango
/// records nothing extra to produce this — there is no analytics, here or anywhere else.
struct StatsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var logging = false
    @State private var editingGoal = false

    private var stats: ReadingStats { library.stats }
    private var activity: ActivityStats { library.activityStats }

    var body: some View {
        NavigationStack {
            Group {
                if stats.isEmpty && !activity.hasActivity {
                    ContentUnavailableView("Nothing to count yet", systemImage: "chart.bar",
                                           description: Text("Add some comics in Sources and this fills in."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            headline
                            ReadingInsightsView()
                            goalCard
                            if activity.hasActivity {
                                timeCard
                                heatmapCard
                                habitsCard
                            }
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
            // The same ••• menu as Earmark's Stats.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Log a Book Read Elsewhere", systemImage: "plus") { logging = true }
                        Button("Change Yearly Goal…", systemImage: "target") { editingGoal = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $logging) { LogBookView() }
            // Here rather than on the goal card, so the menu can open it with nothing to count yet.
            .sheet(isPresented: $editingGoal) { GoalEditor() }
        }
    }

    // MARK: Activity

    private var goalCard: some View {
        StatCard("\(Calendar.current.component(.year, from: .now)) goal") {
            HStack(spacing: 18) {
                GoalRing(done: stats.thisYear, goal: max(1, settings.yearlyGoal), noun: "volumes")
                VStack(alignment: .leading, spacing: 6) {
                    let left = max(0, settings.yearlyGoal - stats.thisYear)
                    Text(left == 0 ? "Goal reached." : "\(left) to go")
                        .font(.headline)
                    Text(GoalRing.pace(done: stats.thisYear, goal: settings.yearlyGoal))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Change goal") { editingGoal = true }
                        .font(.caption)
                }
            }
        }

    }

    private var timeCard: some View {
        StatCard("Time reading") {
            ActivityTimeView(stats: activity, sessionLabel: "Average sitting")
        }
    }

    private var heatmapCard: some View {
        StatCard("Last \(ActivityStats.heatmapWeeks) weeks") {
            ActivityHeatmap(days: activity.heatmap)
        }
    }

    private var habitsCard: some View {
        StatCard("When you read") {
            ActivityHabitsView(stats: activity)
        }
    }

    // MARK: Ratings and the log

    private var ratingsCard: some View {
        StatCard("Ratings") {
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
        StatCard("Read elsewhere") {
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
            StatTile("\(stats.finishedVolumes)", "Volumes finished", systemImage: "checkmark.circle.fill", tint: .green)
            StatTile(stats.pagesRead.formatted(), "Comic pages read", systemImage: "doc.text.fill", tint: .accentColor)
            StatTile(Durations.short(activity.totalSeconds), "Time reading", systemImage: "clock.fill", tint: .blue)
            StatTile("\(activity.currentStreak) day\(activity.currentStreak == 1 ? "" : "s")", "Current streak", systemImage: "flame.fill", tint: .red)
            StatTile("\(stats.finishedSeries)", "Series completed", systemImage: "books.vertical.fill", tint: .purple)
            StatTile("\(activity.daysActive)", "Days read", systemImage: "calendar", tint: .orange)
        }
    }

    // MARK: Charts

    private var monthsChart: some View {
        StatCard("Finished per month") {
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
            StatCard("Library") {
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
            StatCard("By format") {
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
        StatCard("Most read") {
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
        StatCard("Where it lives") {
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
        Text("Worked out from your library, your positions, and time with a book actually open in front of you — the clock stops when the app's in the background, and a page left open longer than three minutes stops counting. Mango collects no analytics and sends nothing anywhere; day totals sync between your own devices through your own iCloud.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

}

import Charts
import SwiftUI

/// A GitHub-style calendar of the last few months: one square per day, darker for more reading.
struct ActivityHeatmap: View {
    let days: [ActivityStats.Day]

    private var weeks: [[ActivityStats.Day]] {
        stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    private var busiest: Double { max(1, days.map(\.seconds).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(color(for: day))
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(Durations.short(day.seconds))")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(shade(level)).frame(width: 10, height: 10)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for day: ActivityStats.Day) -> Color {
        day.seconds <= 0 ? Color.secondary.opacity(0.12) : shade(min(1, day.seconds / busiest))
    }

    private func shade(_ level: Double) -> Color {
        level <= 0 ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.25 + 0.75 * level)
    }
}

/// The yearly goal as a ring: volumes finished this year against what you're aiming for.
struct GoalRing: View {
    let done: Int
    let goal: Int

    private var fraction: Double { goal > 0 ? min(1, Double(done) / Double(goal)) : 0 }

    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(0.18), lineWidth: 12)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.orange.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(done)").font(.title2.weight(.bold)).monospacedDigit()
                Text("of \(goal)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(goal) volumes this year")
    }
}

struct TimeOfDayChart: View {
    let buckets: [ActivityStats.Bucket]

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("When", bucket.name), y: .value("Minutes", bucket.seconds / 60))
                .foregroundStyle(Color.orange.gradient)
                .cornerRadius(4)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 140)
    }
}

import SwiftUI
import UIKit
import WidgetKit

struct ContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: ReadingSnapshot?
    let cover: Image?
}

struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(date: .now, snapshot: ReadingSnapshot(
            comicID: "", title: "Vol. 3", series: "Your Series", positionLabel: "Page 42 of 180",
            fraction: 0.23, isNovel: false, updatedAt: .now), cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        // The app reloads this whenever you close a book; the hourly refresh is only a safety net.
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func load() -> ContinueEntry {
        var cover: Image?
        if let url = SharedReading.coverURL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            cover = Image(uiImage: image)
        }
        return ContinueEntry(date: .now, snapshot: SharedReading.read(), cover: cover)
    }
}

struct ContinueReadingView: View {
    let entry: ContinueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryCircular: circular(snapshot)
            case .systemSmall: small(snapshot)
            default: medium(snapshot)
            }
        } else {
            empty
        }
    }

    // MARK: Home screen

    private func small(_ snapshot: ReadingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(width: 52)
            Spacer(minLength: 0)
            Text(snapshot.series).font(.caption.weight(.semibold)).lineLimit(1)
            Text(snapshot.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            ProgressView(value: snapshot.fraction).tint(.orange)
        }
        .widgetURL(snapshot.deepLink)
    }

    private func medium(_ snapshot: ReadingSnapshot) -> some View {
        HStack(spacing: 14) {
            cover(width: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.isNovel ? "CONTINUE READING · NOVEL" : "CONTINUE READING")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(snapshot.series).font(.headline).lineLimit(2)
                Text(snapshot.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                ProgressView(value: snapshot.fraction).tint(.orange)
                Text(snapshot.positionLabel).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .widgetURL(snapshot.deepLink)
    }

    // MARK: Lock screen

    private func rectangular(_ snapshot: ReadingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(snapshot.series, systemImage: "book.fill").font(.headline).lineLimit(1)
            Text(snapshot.positionLabel).font(.caption).lineLimit(1)
            ProgressView(value: snapshot.fraction)
        }
        .widgetURL(snapshot.deepLink)
    }

    private func circular(_ snapshot: ReadingSnapshot) -> some View {
        Gauge(value: snapshot.fraction) {
            Image(systemName: "book.fill")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetURL(snapshot.deepLink)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed").font(.title2).foregroundStyle(.orange)
            Text("Open a book in Mango").font(.caption).multilineTextAlignment(.center)
        }
        .widgetURL(URL(string: "mango://continue"))
    }

    @ViewBuilder
    private func cover(width: CGFloat) -> some View {
        Group {
            if let cover = entry.cover {
                cover.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.orange.opacity(0.25))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.orange))
            }
        }
        .frame(width: width, height: width * 1.45)
        .clipShape(.rect(cornerRadius: 6))
    }
}

struct ContinueReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueReading", provider: ContinueProvider()) { entry in
            ContinueReadingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Continue Reading")
        .description("The book you're in the middle of, one tap to pick it back up.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct MangoWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueReadingWidget()
    }
}

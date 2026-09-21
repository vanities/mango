import SwiftUI

/// One run: every volume in order, with a Continue button that opens the right one.
struct SeriesDetailView: View {
    let series: Series

    @Environment(LibraryModel.self) private var library
    @State private var readingComic: Comic?
    @State private var editing: Comic?

    private var shelf: Series { library.series.first(where: { $0.id == series.id }) ?? series }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("Volumes") {
                ForEach(shelf.comics) { comic in
                    Button { readingComic = comic } label: {
                        VolumeRow(comic: comic)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            library.setFinished(library.progress(for: comic)?.finished != true, for: comic)
                        } label: {
                            Label("Finished", systemImage: "checkmark")
                        }
                        .tint(.green)
                        Button { editing = comic } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button("Reset progress", systemImage: "arrow.counterclockwise") {
                            library.resetProgress(for: comic)
                        }
                        Button("Hide", systemImage: "eye.slash", role: .destructive) {
                            library.setHidden(true, for: comic)
                        }
                    }
                }
            }
        }
        .navigationTitle(shelf.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readingComic) { ReaderView(comic: $0) }
        .sheet(item: $editing) { EditComicView(comic: $0) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(coverID: shelf.coverID, title: shelf.name, cornerRadius: 10)
                .frame(width: 110)
            VStack(alignment: .leading, spacing: 8) {
                Text(shelf.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                Text(shelf.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Formatting.bytes(shelf.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let next = library.nextUp(in: shelf) {
                    Button {
                        readingComic = next
                    } label: {
                        Label(continueLabel(for: next), systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
    }

    private func continueLabel(for comic: Comic) -> String {
        guard let progress = library.progress(for: comic), progress.isStarted else {
            return shelf.volumeCount > 1 ? "Start \(comic.numberLabel ?? "reading")" : "Read"
        }
        return "Continue \(comic.numberLabel ?? "")".trimmingCharacters(in: .whitespaces)
    }
}

struct VolumeRow: View {
    let comic: Comic
    @Environment(LibraryModel.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            CoverView(coverID: comic.coverID, title: comic.title, cornerRadius: 4)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comic.numberLabel ?? comic.title)
                        .font(.body)
                        .lineLimit(1)
                    if let subtitle = comic.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(comic.formatLabel)
                    if let pages = comic.pageCount {
                        Text("· \(pages) pages")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let progress = library.progress(for: comic), progress.isStarted {
                    ProgressBar(fraction: progress.fraction)
                        .frame(maxWidth: 160)
                }
            }
            Spacer()
            if library.progress(for: comic)?.finished == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(.rect)
    }
}

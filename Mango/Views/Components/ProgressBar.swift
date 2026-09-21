import SwiftUI

/// A thin read-through bar for a cover or a row. Nothing when the book hasn't been started.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Cover + progress + label, used in the Continue Reading row and the series grid.
struct ComicThumbnail: View {
    let comic: Comic
    var showsProgress = true

    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                CoverView(coverID: comic.coverID, title: comic.title)
                if showsProgress, let progress = library.progress(for: comic), progress.isStarted {
                    ProgressBar(fraction: progress.fraction)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
            Text([comic.numberLabel, comic.subtitle].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .lineLimit(1)
            if let progress = library.progress(for: comic), progress.isStarted {
                Text(comic.isNovel ? progress.novelLabel : progress.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

import SwiftUI

/// Five tappable stars. Tapping the current rating clears it, so there's a way back to
/// "unrated" without a separate button.
struct StarRating: View {
    let rating: Int?
    var size: CGFloat = 22
    var onChange: (Int?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onChange(rating == star ? nil : star)
                } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(star <= (rating ?? 0) ? Color.yellow : Color.secondary)
                        // Small glyph, full-size target.
                        .frame(width: max(44, size + 12), height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star == rating ? .isSelected : [])
            }
        }
    }
}

/// Read-only stars for rows and lists.
struct StarsView: View {
    let rating: Int
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary.opacity(0.4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating) out of 5 stars")
    }
}

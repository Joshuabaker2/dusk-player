import SwiftUI

/// One Plex match candidate: poster, title and year, and the start of its
/// summary. Same-name films from the same year are common, and the poster and
/// summary are what let someone pick the right one at a glance.
struct PlexMatchCandidateRow<Accessory: View>: View {
    let candidate: PlexMatchCandidate
    var isCurrent = false
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlexMatchCandidatePoster(url: candidate.thumbURL)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(2)

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.duskTextPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.duskSurface.opacity(0.86), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
                            }
                    }
                }

                if let summary = candidate.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)

            accessory()
                .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Candidate posters come from Plex's public image proxy, so they are fetched
/// without Plex credentials (no `PlexService` is passed to the loader).
private struct PlexMatchCandidatePoster: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.duskSurface)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
        .frame(width: 48, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = try? await DuskImageLoader.shared.image(for: url)
        }
    }
}

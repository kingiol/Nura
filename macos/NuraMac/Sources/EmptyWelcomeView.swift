import SwiftUI

struct EmptyWelcomeView: View {
    let recentItems: [HistoryEntry]
    let isDropTargeted: Bool
    let errorMessage: String?
    let onOpen: () -> Void
    let onOpenRecent: (MediaItem) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "play.circle.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)

                Text(isDropTargeted ? L10n.text("Release to Open") : L10n.text("Open Video"))
                    .font(.title2.weight(.semibold))

                Text(isDropTargeted ? L10n.text("Drop your media file to begin") : L10n.text("Choose a file or drop it anywhere here"))
                    .foregroundStyle(.secondary)

                Button(L10n.text("Select Video"), action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcome.select-video")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("welcome.error")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !recentItems.isEmpty {
                VStack {
                    Spacer()
                    recentSection
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(32)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isDropTargeted)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Recent"))
                .font(.headline)

            ForEach(Array(recentItems.enumerated()), id: \.element.id) { index, entry in
                WelcomeRecentRow(
                    entry: entry,
                    index: index,
                    onOpen: { onOpenRecent(entry.item) }
                )
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

private struct WelcomeRecentRow: View {
    let entry: HistoryEntry
    let index: Int
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(entry.item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 16)
                Text(resumeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("welcome.resume.\(index)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("welcome.recent.\(index)")
        .accessibilityLabel(entry.item.title)
        .accessibilityValue(resumeLabel)
    }

    private var resumeLabel: String {
        guard let seconds = entry.resumeSeconds, seconds.isFinite, seconds > 0 else {
            return L10n.text("Start")
        }
        return L10n.format("Resume %@", format(seconds))
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let remaining = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%02d:%02d", minutes, remaining)
    }
}

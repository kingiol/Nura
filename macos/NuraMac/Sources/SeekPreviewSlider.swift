import AppKit
import SwiftUI

struct ABLoopProgressGeometry: Equatable {
    let start: CGFloat
    let end: CGFloat?

    static func resolve(duration: Double?, start: Double?, end: Double?) -> Self? {
        guard let duration, duration.isFinite, duration > 0,
              let start, start.isFinite else {
            return nil
        }

        let normalizedStart = CGFloat(min(max(start / duration, 0), 1))
        let normalizedEnd = end.flatMap { end -> CGFloat? in
            guard end.isFinite else { return nil }
            return CGFloat(min(max(end / duration, 0), 1))
        }
        return Self(start: normalizedStart, end: normalizedEnd)
    }
}

struct SeekPreviewSlider: View {
    private let previewBubbleSize = CGSize(width: 192, height: 136)

    @Binding var value: Double
    let duration: Double
    let mediaDuration: Double?
    let abLoopStart: Double?
    let abLoopEnd: Double?
    let previewImage: NSImage?
    let previewPosition: Double?
    let previewVisible: Bool
    let onEditingChanged: (Bool) -> Void
    let onPreviewPositionChanged: (Double) -> Void
    let onPreviewEnded: () -> Void

    @State private var isEditing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            value = newValue
                            if isEditing {
                                onPreviewPositionChanged(newValue)
                            }
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        isEditing = editing
                        onEditingChanged(editing)
                        if !editing {
                            onPreviewEnded()
                        }
                    }
                )
                .controlSize(.small)
                .frame(height: 24)
                .accessibilityIdentifier("player.seek-slider")
                .accessibilityLabel(L10n.text("Playback position"))
                .accessibilityValue(L10n.format("%@ of %@", formatTime(previewPosition ?? value), formatTime(duration)))

                if let loopGeometry = ABLoopProgressGeometry.resolve(
                    duration: mediaDuration,
                    start: abLoopStart,
                    end: abLoopEnd
                ) {
                    loopOverlay(loopGeometry, in: proxy.size)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(1)
                }

                if previewVisible, previewImage != nil {
                    previewBubble
                        .frame(width: previewBubbleSize.width, height: previewBubbleSize.height)
                        .position(x: previewX(in: proxy.size.width), y: -64)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let normalized = min(max(location.x / max(proxy.size.width, 1), 0), 1)
                    onPreviewPositionChanged(normalized * duration)
                case .ended:
                    if !isEditing { onPreviewEnded() }
                }
            }
            .onHover { hovering in
                if hovering {
                    onPreviewPositionChanged(value)
                } else if !isEditing {
                    onPreviewEnded()
                }
            }
        }
        .frame(height: 24)
        .accessibilityElement(children: .contain)
    }

    private var previewBubble: some View {
        VStack(spacing: 4) {
            Group {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 180, height: 102)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let previewPosition {
                Text(formatTime(previewPosition))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func loopOverlay(_ geometry: ABLoopProgressGeometry, in size: CGSize) -> some View {
        let startX = geometry.start * size.width
        let endX = geometry.end.map { $0 * size.width }

        return ZStack(alignment: .topLeading) {
            if let endX {
                Capsule()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: max(0, endX - startX), height: 3)
                    .position(x: (startX + endX) / 2, y: size.height / 2)
            }

            loopMarker("A", at: startX)

            if let endX {
                loopMarker("B", at: endX)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func loopMarker(_ label: String, at x: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tint)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: 9)
        }
        .frame(width: 16, height: 22)
        .position(x: x, y: 11)
    }

    private func previewX(in width: CGFloat) -> CGFloat {
        guard let previewPosition, duration.isFinite, duration > 0 else { return width / 2 }
        let halfWidth = previewBubbleSize.width / 2
        return min(max(CGFloat(previewPosition / duration) * width, halfWidth), max(width - halfWidth, halfWidth))
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

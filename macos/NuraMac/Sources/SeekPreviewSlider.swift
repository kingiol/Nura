import AppKit
import SwiftUI

struct SeekPreviewSlider: View {
    @Binding var value: Double
    let duration: Double
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
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(previewPosition ?? value)) of \(formatTime(duration))")

                if previewVisible {
                    previewBubble
                        .frame(width: 180)
                        .offset(x: previewX(in: proxy.size.width) - 90, y: -30)
                        .allowsHitTesting(false)
                        .zIndex(1)
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
                } else {
                    Color.black.opacity(0.55)
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

    private func previewX(in width: CGFloat) -> CGFloat {
        guard let previewPosition, duration.isFinite, duration > 0 else { return width / 2 }
        return min(max(CGFloat(previewPosition / duration) * width, 90), max(width - 90, 90))
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

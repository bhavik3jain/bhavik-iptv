import Core
import SwiftUI

/// What is playing while someone browses: the way back to it, and a way to stop
/// it. Above the tab bar on a phone, in a corner on the wider layouts, and on
/// the TV beside the tab bar, where right from the last tab reaches it.
struct BackgroundPlaybackBar: View {
    let item: BackgroundPlayback
    let onReturn: () -> Void
    let onStop: () -> Void

    @Environment(\.hearthLayout) private var layout

    var body: some View {
        if layout == .tv {
            tvBar
        } else {
            touchBar
        }
    }

    private var tvBar: some View {
        HStack(spacing: 12) {
            Button(action: onReturn) {
                Label {
                    Text(item.title).lineLimit(1)
                } icon: {
                    Image(systemName: item.systemImage)
                }
            }
            // Beside the tab bar, whose eight tabs (Profiles since
            // 2026-11-10) leave about this much on a 1920-point screen.
            .frame(maxWidth: 200)
            .accessibilityLabel(Text(item.returnLabel))
            Button(action: onStop) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text(item.stopLabel))
        }
        .buttonStyle(.hearthTV)
        .hearthFocusSection()
    }

    private var touchBar: some View {
        HStack(spacing: 4) {
            Button(action: onReturn) {
                HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HearthColor.accent)
                        .accessibilityHidden(true)
                    Text(item.title)
                        .font(.hearthBody.weight(.semibold))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.returnLabel))
            Button(action: onStop) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HearthColor.textSecondary)
                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.stopLabel))
        }
        .frame(maxWidth: layout == .compact ? .infinity : 380)
        .background(Capsule().fill(HearthColor.surfaceRaised))
        .overlay(Capsule().strokeBorder(HearthColor.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

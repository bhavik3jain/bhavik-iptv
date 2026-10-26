import CatalogKit
import Core
import SwiftUI

/// The card a tapped programme raises over the guide (LIV-3, LIV-4; mockup
/// 03): the channel's logo, the programme's title, "101 Cityline News ·
/// 20:00–21:00 · 18 min left", a heart for the channel (FAV-1, hidden for
/// a Guest), and Watch live / From the start as `ProgrammeActions` decides.
/// Floats above the tab bar; drag it down, tap the cell again or press
/// Escape to put it away.
struct ProgrammeCard: View {
    let channel: CatalogChannel
    let programme: CatalogProgramme?
    let now: Date
    let isFavorite: Bool
    let showsFavorite: Bool
    /// The close button; the phone layout leaves it out, as the mockup does,
    /// and relies on dragging the card down.
    let showsClose: Bool
    let onToggleFavorite: () -> Void
    let onAction: (ProgrammeAction) -> Void
    let onClose: () -> Void

    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: ProgrammePhase? {
        programme.map { .of(start: $0.start, end: $0.end, now: now) }
    }

    private var actions: ProgrammeActions {
        ProgrammeActions.make(
            phase: phase,
            channelHasArchive: channel.hasArchive,
            isPlayable: programme.map { CatchupRules.isPlayable($0, on: channel, now: now) } ?? false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ChannelLogo(name: channel.name, url: channel.logoURL, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(programme?.title ?? channel.name)
                        .font(.hearthHeadline)
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsFavorite {
                    FavoriteHeartButton(isFavorite: isFavorite, action: onToggleFavorite)
                }
                if showsClose {
                    IconCircleButton(systemName: "xmark", label: String(localized: "Close"), size: 32, style: .raised, action: onClose)
                }
            }

            if let detail {
                Text(detail)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !actions.isEmpty {
                HStack(spacing: 10) {
                    if let primary = actions.primary {
                        button(primary, isPrimary: true)
                    }
                    if let secondary = actions.secondary {
                        button(secondary, isPrimary: false)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                .fill(HearthColor.surfaceOverlay)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                .strokeBorder(HearthColor.stroke, lineWidth: 1)
        )
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { dragOffset = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 70 || value.predictedEndTranslation.height > 160 {
                        onClose()
                    }
                    withAnimation(reduceMotion ? nil : .snappy) { dragOffset = 0 }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onClose)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var subtitle: String {
        guard let programme else {
            return ChannelText.numberedName(number: channel.number, name: channel.name) + " · " + String(localized: "No guide information")
        }
        return ProgrammeText.cardSubtitle(channelNumber: channel.number, channelName: channel.name, start: programme.start, end: programme.end, now: now)
    }

    /// The summary, or a line saying why there's nothing to play.
    private var detail: String? {
        if let summary = programme?.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if phase == .aired, actions.primary == nil {
            return channel.hasArchive
                ? String(localized: "This programme has left the channel's archive.")
                : String(localized: "This channel doesn't keep past programmes.")
        }
        return nil
    }

    private func button(_ action: ProgrammeAction, isPrimary: Bool) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .labelStyle(CardButtonLabelStyle())
                .frame(maxWidth: .infinity)
        }
        .modifier(CardButtonStyle(isPrimary: isPrimary))
    }
}

/// The card's buttons: amber or raised, 44 pt, sharing the width.
private struct CardButtonStyle: ViewModifier {
    let isPrimary: Bool

    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.hearthPrimary(shape: .rounded, size: .regular))
        } else {
            content.buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))
        }
    }
}

/// An icon and title side by side with the mockup's 8 pt gap.
private struct CardButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 14, weight: .semibold))
            configuration.title
        }
    }
}

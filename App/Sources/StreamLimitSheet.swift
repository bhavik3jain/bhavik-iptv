import Core
import SwiftUI

/// HH-6: before playing on a source at its limit, say so and name who is
/// using it; "Watch anyway" stays possible. Uses Core's stream bar and
/// grouped card, as Household's stream rows do.
struct StreamLimitSheet: View {
    let prompt: StreamLimitPrompt
    let onDecision: (PlaybackCoordinator.LimitDecision) -> Void

    @Environment(\.hearthLayout) private var layout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing) {
                header
                StreamBar(
                    prompt.sourceName,
                    usage: StreamBarUsage(inUse: prompt.inUse, limit: prompt.limit),
                    caption: usageCaption
                )
                if !prompt.watchers.isEmpty {
                    GroupedCard(title: String(localized: "Watching now")) {
                        ForEach(prompt.watchers) { watcher in
                            CardRow(watcher.title.isEmpty ? watcher.profileName : watcher.title,
                                    subtitle: String(localized: "\(watcher.profileName) · \(watcher.deviceName)")) {
                                AvatarCircle(name: watcher.profileName, palette: watcher.palette, size: 36)
                            }
                            .padding(.horizontal, HearthMetrics.groupedRowInset)
                        }
                    }
                }
                if prompt.outsideHousehold > 0 {
                    Text(outsideText)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
                actions
            }
            .padding(HearthMetrics.screenPadding)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .hearthScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .frame(width: 48, height: 48)
                .background(Circle().fill(HearthColor.surface))
                .accessibilityHidden(true)
            Text("\(prompt.sourceName) is at its limit")
                .font(.hearthTitle)
                .tracking(HearthMetrics.titleTracking)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Starting \(prompt.intent.title) may stop someone else's stream — the provider decides which.")
                .font(.hearthBody)
                .foregroundStyle(HearthColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageCaption: String {
        String(localized: "\(prompt.inUse) of \(prompt.limit) streams in use")
    }

    private var outsideText: String {
        String(localized: "The provider counts \(prompt.outsideHousehold) more outside this household, or on a device that hasn't synced yet.")
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                onDecision(.watchAnyway)
            } label: {
                Text("Watch anyway").frame(maxWidth: .infinity)
            }
            .buttonStyle(.hearthPrimary(shape: .rounded, size: .large))
            .keyboardShortcut(.defaultAction)

            if let alternative = prompt.alternative {
                Button {
                    onDecision(.useAlternative)
                } label: {
                    Text("Watch on \(alternative.sourceName) instead").frame(maxWidth: .infinity)
                }
                .buttonStyle(.hearthSecondary(shape: .rounded, size: .large))
                .accessibilityHint(Text("Plays the same channel from another source"))
            }

            Button {
                onDecision(.cancel)
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.hearthSecondary(shape: .rounded, size: .large))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 4)
    }
}

import CatalogKit
import Core
import SwiftUI

// What Home shows before there is a Home: no source yet, the first import
// running, or the first import failed. Each replaces the sections under the
// header and sits in the middle of the remaining screen.

/// The household has no source (HOME-1 empty state). Only someone who can
/// manage the household can add one; everyone else is told who can.
struct NoSourcesState: View {
    let canManageHousehold: Bool

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        if canManageHousehold {
            EmptyStateView(
                systemName: "antenna.radiowaves.left.and.right",
                title: String(localized: "Add a source to start watching", bundle: .module),
                message: String(localized: "Sign in with a Stalker portal, an Xtream login or an M3U playlist. Everyone in the household shares it.", bundle: .module),
                actionTitle: String(localized: "Add a source", bundle: .module)
            ) {
                openRoute(.sourceEditor(sourceID: nil))
            }
        } else {
            EmptyStateView(
                systemName: "antenna.radiowaves.left.and.right",
                title: String(localized: "Add a source to start watching", bundle: .module),
                message: String(localized: "Ask the household's owner to add a source. Its channels, movies and shows appear here for everyone.", bundle: .module)
            )
        }
    }
}

/// A source's first import is running (or waiting its turn): nothing to show
/// yet, so say what's happening and how far along it is.
struct FirstRefreshState: View {
    let sourceName: String?
    let progress: Double?
    let message: String?

    var body: some View {
        VStack(spacing: 16) {
            HearthLogoMark(size: 36)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.hearthDisplay(20, weight: .semibold, relativeTo: .title3))
                    .foregroundStyle(HearthColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message ?? String(localized: "Channels, movies and shows appear here as soon as they're imported. A large portal can take a few minutes.", bundle: .module))
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .tint(HearthColor.accent)
            .accessibilityLabel(Text(title))
        }
        .frame(maxWidth: 380)
        .hearthCard(padding: 28)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        if let sourceName {
            return String(localized: "Getting \(sourceName) ready", bundle: .module, comment: "First import of a source; the placeholder is the source's name")
        }
        return String(localized: "Getting your sources ready", bundle: .module)
    }
}

/// Every source failed its first import: offer another try, and the source's
/// settings to whoever can change them.
struct RefreshFailedState: View {
    let sourceID: UUID
    let sourceName: String?
    let message: String
    let canManageHousehold: Bool

    @Environment(CatalogService.self) private var catalog
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                systemName: "exclamationmark.triangle",
                title: title,
                message: message,
                actionTitle: String(localized: "Try again", bundle: .module)
            ) {
                Task { await catalog.refresh(sourceID: sourceID, force: true) }
            }
            if canManageHousehold {
                Button(String(localized: "Check the source", bundle: .module)) {
                    openRoute(.sourceEditor(sourceID: sourceID))
                }
                .buttonStyle(.hearthSecondary)
                .padding(.top, -12)
            }
        }
    }

    private var title: String {
        if let sourceName {
            return String(localized: "Couldn't load \(sourceName)", bundle: .module, comment: "A source's first import failed; the placeholder is its name")
        }
        return String(localized: "Couldn't load your source", bundle: .module)
    }
}

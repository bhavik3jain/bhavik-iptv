import Core
import HouseholdKit
import SwiftUI

/// "Who's watching?" on the Apple TV (mockup 01 across a room; PRF-2, PRF-3,
/// PRF-5, HH-5): the logo, the title over the household's name, one row of
/// large avatars the remote moves along (the last one used here takes focus
/// first), and under it who is streaming now and the way to the household.
///
/// Profiles aren't added or edited here — that is a form of names and PINs,
/// better typed on an iPhone, iPad or Mac in the same household, and the TV
/// says so. Choosing a profile asks for its PIN on the TV's own keypad.
struct WhoIsWatchingTVScreen: View {
    let onManageHousehold: () -> Void

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @State private var pinRequest: PINFlowRequest?
    @FocusState private var focusedProfile: UUID?

    var body: some View {
        let _ = store.revision
        VStack(spacing: 0) {
            HStack {
                HearthLogo()
                    .scaleEffect(1.5, anchor: .leading)
                Spacer()
            }
            Spacer(minLength: 40)
            VStack(spacing: 14) {
                Text("Who’s watching?", bundle: .module)
                    .font(.hearthTVLargeTitle)
                    .tracking(-0.8)
                    .foregroundStyle(HearthColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if store.hasHousehold {
                    Text(store.household.name)
                        .font(.hearthTVCallout)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            Group {
                if store.hasHousehold {
                    profileRow
                } else {
                    waiting
                }
            }
            .padding(.top, 56)
            Spacer(minLength: 40)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                footer(now: context.date)
            }
        }
        .padding(.horizontal, HearthTVMetrics.gutter)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hearthScreenBackground()
        .pinFlow($pinRequest) { pin, ids in
            ids.contains { store.verifyPIN(pin, for: $0) }
        }
        .defaultFocus($focusedProfile, initialProfileID)
        // After Switch Profile, Menu goes back to the profile just left
        // rather than out of the app; at launch it leaves as usual.
        .hearthOnExitCommand(previousProfile.map { profile in { choose(profile) } })
    }

    /// The profile Switch Profile left, if the household still has it.
    private var previousProfile: ProfileRecord? {
        session.previousProfileID.flatMap { id in store.profiles.first { $0.id == id } }
    }

    // MARK: Profiles

    private var profileRow: some View {
        HStack(alignment: .top, spacing: 56) {
            ForEach(store.profiles) { profile in
                Button {
                    choose(profile)
                } label: {
                    TVProfileTileLabel(
                        name: profile.name,
                        palette: profile.avatarColor,
                        symbol: profile.avatarSymbol,
                        caption: caption(for: profile),
                        isLocked: profile.hasPIN
                    )
                }
                .buttonStyle(TVProfileButtonStyle())
                .focused($focusedProfile, equals: profile.id)
                .accessibilityHint(profile.hasPIN ? Text("Asks for its PIN", bundle: .module) : Text("Opens this profile", bundle: .module))
            }
        }
        .frame(maxWidth: .infinity)
        .hearthFocusSection()
    }

    /// The profile used last on this TV, else the first.
    private var initialProfileID: UUID? {
        if let last = session.lastUsedProfileID, store.profiles.contains(where: { $0.id == last }) { return last }
        return store.profiles.first?.id
    }

    private var waiting: some View {
        VStack(spacing: 24) {
            ProgressView()
                .tint(HearthColor.accent)
            Text("Looking for your household in iCloud…", bundle: .module)
                .font(.hearthTVCallout)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .frame(minHeight: 300)
    }

    private func caption(for profile: ProfileRecord) -> String? {
        ProfileCaption.text(
            for: profile,
            isWatchingNow: store.activePlaybacks.contains { $0.profileID == profile.id && !$0.isStale() },
            latestProgress: profile.kind == .standard ? store.continueWatching(profileID: profile.id, limit: 1).first : nil,
            isLastUsedHere: session.lastUsedProfileID == profile.id
        )
    }

    /// Opens the profile, after its PIN (and an adult's when leaving Kids).
    private func choose(_ profile: ProfileRecord) {
        let steps = PINSteps.forSwitch(from: session.currentProfile, to: profile, profiles: store.profiles)
        let select = { @MainActor in
            guard let fresh = store.profiles.first(where: { $0.id == profile.id }) else { return }
            session.select(fresh)
        }
        if steps.isEmpty {
            select()
        } else {
            pinRequest = PINFlowRequest(steps: steps, perform: select)
        }
    }

    // MARK: Footer

    /// Who it's shared with, who is streaming now, and Household — a line
    /// rather than the phone's card, so the avatars keep the screen.
    private func footer(now: Date) -> some View {
        let rows = WatchingNowRow.rows(playbacks: store.activePlaybacks, profiles: store.profiles, sources: store.sources, now: now)
        let summary = HouseholdSummary.make(
            isShared: store.household.isShared,
            otherMembers: store.members.filter { !$0.isCurrentUser }.count,
            syncsWithICloud: syncsWithICloud
        )
        return HStack(alignment: .center, spacing: 32) {
            Image(systemName: store.household.isShared ? "person.2.fill" : "house.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(HearthColor.surfaceRaised))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.hearthTVHeadline)
                    .foregroundStyle(HearthColor.textPrimary)
                Text(rows.first?.sentence ?? summary.subtitle)
                    .font(.hearthTVCaption)
                    .foregroundStyle(rows.isEmpty ? HearthColor.textSecondary : HearthColor.accent)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 24)
            if session.canManageHousehold, store.hasHousehold {
                Button {
                    let steps = PINSteps.forManaging(profiles: store.profiles)
                    if steps.isEmpty {
                        onManageHousehold()
                    } else {
                        pinRequest = PINFlowRequest(steps: steps) { onManageHousehold() }
                    }
                } label: {
                    Label {
                        Text("Household", bundle: .module)
                    } icon: {
                        Image(systemName: "person.2")
                    }
                }
                .buttonStyle(.hearthTV)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(HearthColor.surface)
        )
        .hearthFocusSection()
    }

    private var syncsWithICloud: Bool {
        guard case .cloud = store.mode else { return false }
        return store.syncStatus != .noAccount
    }
}

/// An avatar, the name with a lock when there's a PIN, and the caption.
private struct TVProfileTileLabel: View {
    let name: String
    let palette: AvatarPalette
    let symbol: String?
    let caption: String?
    let isLocked: Bool

    var body: some View {
        VStack(spacing: 22) {
            AvatarTile(name: name, palette: palette, symbol: symbol, size: 200, isLocked: false)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text(name)
                        .font(.hearthText(30, weight: .semibold, relativeTo: .headline))
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .accessibilityLabel(Text("PIN", bundle: .module))
                    }
                }
                Text(caption ?? " ")
                    .font(.hearthTVCaption)
                    .lineLimit(1)
            }
        }
        .frame(width: 240)
    }
}

/// The avatar grows and gets a white ring with focus (white reads on every
/// avatar colour, amber included); the name brightens.
private struct TVProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVProfileButtonBody(configuration: configuration)
    }
}

private struct TVProfileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? HearthColor.textPrimary : HearthColor.textSecondary)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 62, style: .continuous)
                    .strokeBorder(HearthColor.textPrimary, lineWidth: 6)
                    .frame(width: 216, height: 216)
                    .offset(y: -8)
                    .opacity(isFocused ? 1 : 0)
            }
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 1.04 : (isFocused ? 1.1 : 1)))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 24, y: 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
    }
}

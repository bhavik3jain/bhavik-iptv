import Core
import HouseholdKit
import SwiftUI

/// "Who's watching?" (mockup 01; PRF-1, PRF-2, PRF-3, PRF-4, PRF-5, HH-5).
///
/// The logo and Edit; the title over the household's name; a grid of
/// profiles with a lock beside a name that asks for a PIN and a caption under
/// each (`ProfileCaption`); a dashed Add profile tile while the household has
/// room and this member may manage; and the household card at the foot:
/// who it's shared with, who is streaming now, Manage household.
///
/// On the phone the card sits at the bottom of the screen as in the mockup;
/// in the sidebar layout (iPad, Mac, iPhone Duo opened) everything is a
/// centred column of readable width.
struct WhoIsWatchingScreen: View {
    let onManageHousehold: () -> Void

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    @State private var isEditing = false
    @State private var editorTarget: EditorTarget?
    @State private var pinRequest: PINFlowRequest?

    /// Which profile the editor sheet opens; nil makes a new one.
    struct EditorTarget: Identifiable {
        var profileID: UUID?
        var id: String { profileID?.uuidString ?? "new" }
    }

    private var isSidebar: Bool { layout == .sidebar }
    private var avatarSize: CGFloat { isSidebar ? 112 : 96 }

    /// Managing is the member's right (owner or manager), checked here with
    /// whatever profile is open: a Kids or Guest profile never manages.
    private var canManage: Bool { session.canManageHousehold }

    var body: some View {
        // Read so the grid, captions and card follow every store change.
        let _ = store.revision
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    header
                    if isSidebar { Spacer(minLength: 0) }
                    titleBlock
                    if store.hasHousehold {
                        profileGrid
                    } else {
                        waitingForHousehold
                    }
                    if !isSidebar { Spacer(minLength: 0) }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        householdCard(now: context.date)
                    }
                    if isSidebar { Spacer(minLength: 0) }
                }
                .padding(.horizontal, HearthMetrics.screenPadding)
                .padding(.top, isSidebar ? 28 : 16)
                .padding(.bottom, 24)
                .frame(maxWidth: isSidebar ? 640 : .infinity)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .hearthScreenBackground()
        .sheet(item: $editorTarget) { target in
            ProfileEditorSheet(profileID: target.profileID)
        }
        .pinFlow($pinRequest) { pin, ids in
            ids.contains { store.verifyPIN(pin, for: $0) }
        }
        .onChange(of: canManage) { _, allowed in
            if !allowed { isEditing = false }
        }
        .onChange(of: store.profiles.isEmpty) { _, isEmpty in
            if isEmpty { isEditing = false }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HearthLogo()
            Spacer(minLength: 12)
            if canManage, store.hasHousehold, !store.profiles.isEmpty {
                editButton
            }
        }
    }

    private var editButton: some View {
        Button {
            if isEditing {
                isEditing = false
            } else {
                guarded(PINSteps.forManaging(profiles: store.profiles)) { isEditing = true }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text(isEditing ? String(localized: "Done", bundle: .module) : String(localized: "Edit", bundle: .module))
                    .font(.hearthText(15, weight: .medium, relativeTo: .body))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .foregroundStyle(isEditing ? HearthColor.onAccent : HearthColor.textPrimary)
            .background(Capsule().fill(isEditing ? HearthColor.accent : HearthColor.surface))
            .overlay(Capsule().strokeBorder(isEditing ? Color.clear : HearthColor.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.hearthTile)
        .accessibilityLabel(Text(isEditing ? String(localized: "Done editing profiles", bundle: .module) : String(localized: "Edit profiles", bundle: .module)))
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text("Who’s watching?", bundle: .module)
                .font(.hearthLargeTitle)
                .tracking(HearthMetrics.titleTracking)
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if store.hasHousehold {
                Text(isEditing ? String(localized: "Choose a profile to edit", bundle: .module) : store.household.name)
                    .font(.hearthText(15, relativeTo: .subheadline))
                    .foregroundStyle(isEditing ? HearthColor.accent : HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var waitingForHousehold: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(HearthColor.accent)
            Text("Looking for your household in iCloud…", bundle: .module)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityElement(children: .combine)
    }

    // MARK: Profiles

    private var profileGrid: some View {
        let columns = [GridItem(.adaptive(minimum: avatarSize, maximum: avatarSize + 44), spacing: 18, alignment: .top)]
        return LazyVGrid(columns: columns, spacing: 26) {
            ForEach(store.profiles) { profile in
                profileButton(profile)
            }
            if canManage, ProfileEditRules.canAdd(profileCount: store.profiles.count) {
                DashedAddTile(String(localized: "Add profile", bundle: .module), size: avatarSize) {
                    // In edit mode the adult's PIN was already given.
                    guarded(isEditing ? [] : PINSteps.forManaging(profiles: store.profiles)) {
                        editorTarget = EditorTarget(profileID: nil)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func profileButton(_ profile: ProfileRecord) -> some View {
        Button {
            choose(profile)
        } label: {
            ProfileTile(
                name: profile.name,
                palette: profile.avatarColor,
                symbol: profile.avatarSymbol,
                subtitle: caption(for: profile),
                isLocked: profile.hasPIN,
                size: avatarSize
            )
            .overlay(alignment: .top) {
                if isEditing {
                    editBadge
                }
            }
        }
        .buttonStyle(.hearthTile)
        .accessibilityHint(hint(for: profile))
    }

    /// The amber pencil on each avatar's corner while editing.
    private var editBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(HearthColor.onAccent)
            .frame(width: 30, height: 30)
            .background(Circle().fill(HearthColor.accent))
            .overlay(Circle().strokeBorder(HearthColor.background, lineWidth: 2))
            .frame(width: avatarSize, alignment: .topTrailing)
            .offset(x: 8, y: -8)
            .accessibilityHidden(true)
            .transition(.scale.combined(with: .opacity))
    }

    private func caption(for profile: ProfileRecord) -> String? {
        ProfileCaption.text(
            for: profile,
            isWatchingNow: store.activePlaybacks.contains { $0.profileID == profile.id && !$0.isStale() },
            latestProgress: profile.kind == .standard ? store.continueWatching(profileID: profile.id, limit: 1).first : nil,
            isLastUsedHere: session.lastUsedProfileID == profile.id
        )
    }

    private func hint(for profile: ProfileRecord) -> Text {
        if isEditing { return Text("Edits this profile", bundle: .module) }
        if profile.hasPIN { return Text("Asks for its PIN", bundle: .module) }
        return Text("Opens this profile", bundle: .module)
    }

    /// Opens the profile (after its PIN, and an adult's when leaving a Kids
    /// profile), or its editor while editing.
    private func choose(_ profile: ProfileRecord) {
        if isEditing {
            editorTarget = EditorTarget(profileID: profile.id)
            return
        }
        let steps = PINSteps.forSwitch(from: session.currentProfile, to: profile, profiles: store.profiles)
        guarded(steps) {
            // The record as it is now: a sync may have changed it while the
            // PIN pad was up.
            guard let fresh = store.profiles.first(where: { $0.id == profile.id }) else { return }
            session.select(fresh)
        }
    }

    /// Runs `action` at once when no PIN is needed, else after the PIN sheet.
    private func guarded(_ steps: [PINStep], action: @escaping @MainActor () -> Void) {
        if steps.isEmpty {
            action()
        } else {
            pinRequest = PINFlowRequest(steps: steps, perform: action)
        }
    }

    // MARK: Household card

    private func householdCard(now: Date) -> some View {
        let rows = WatchingNowRow.rows(playbacks: store.activePlaybacks, profiles: store.profiles, sources: store.sources, now: now)
        let shownRows = rows.prefix(Self.maxWatchingRows)
        return VStack(spacing: 16) {
            sharingRow
            if !shownRows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(shownRows) { row in
                        watchingRow(row)
                    }
                    if rows.count > Self.maxWatchingRows {
                        Text("and \(rows.count - Self.maxWatchingRows) more", bundle: .module)
                            .font(.hearthCaption)
                            .foregroundStyle(HearthColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                }
            }
            if canManage, store.hasHousehold {
                Button {
                    // The gate is shared: an adult's PIN first, as for Edit.
                    guarded(PINSteps.forManaging(profiles: store.profiles)) { onManageHousehold() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Manage household", bundle: .module)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ManageHouseholdButtonStyle())
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(HearthColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(HearthColor.hairline, lineWidth: 1)
        )
    }

    /// More streams than this collapse into "and N more": the card is a
    /// glance, Household has the full list.
    private static let maxWatchingRows = 3

    private var sharingRow: some View {
        let members = MemberPalette.ordered(store.members)
        let summary = HouseholdSummary.make(
            isShared: store.household.isShared,
            otherMembers: members.filter { !$0.isCurrentUser }.count,
            syncsWithICloud: syncsWithICloud
        )
        return HStack(spacing: 12) {
            if members.isEmpty {
                CardTile(systemName: store.household.isShared ? "person.2.fill" : "house.fill", size: 38)
            } else {
                AvatarStack(
                    members.enumerated().map { index, member in
                        AvatarStack.Member(name: member.displayName, palette: MemberPalette.palette(at: index))
                    },
                    maxVisible: 2
                )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .font(.hearthText(15, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(HearthColor.textPrimary)
                Text(summary.subtitle)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var syncsWithICloud: Bool {
        guard case .cloud = store.mode else { return false }
        return store.syncStatus != .noAccount
    }

    private func watchingRow(_ row: WatchingNowRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HearthColor.accent)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.sentence)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textPrimary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.hearthCaption)
                        .foregroundStyle(HearthColor.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let streams = row.streams {
                Text(streams)
                    .font(.hearthMono(12, relativeTo: .caption))
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HearthColor.background)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.spoken))
    }
}

/// "Manage household ›": a 44-pt rounded button in the card's button colour
/// (`surfaceButton`, a shade darker than `hearthSecondary`'s fill), as in the
/// mockup.
private struct ManageHouseholdButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hearthText(15, weight: .medium, relativeTo: .body))
            .foregroundStyle(HearthColor.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .background(
                RoundedRectangle(cornerRadius: HearthMetrics.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? HearthColor.surfaceRaised : HearthColor.surfaceButton)
            )
            .contentShape(Rectangle())
    }
}

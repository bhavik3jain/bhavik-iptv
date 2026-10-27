import Core
import HouseholdKit
import SwiftUI

/// The profile switcher (PRF-8): Home's header on the phone (mockup 02: the
/// avatar, the name in Sora and a chevron) and the card at the top of the Mac
/// sidebar (mockup 07: avatar, name, household, up/down chevrons).
///
/// Its menu lists the other profiles, "Who's watching?", and Manage household
/// and Settings when this profile may open them. A profile with a PIN asks
/// for it in a sheet (PRF-3); leaving a Kids profile asks for an adult's PIN
/// first when any adult has one (PRF-4, `PINSteps.forSwitch`).
struct ProfileSwitcher: View {
    let style: ProfileSwitcherMenu.Style

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.hearthLayout) private var layout

    @State private var pinRequest: PINFlowRequest?

    /// Home's header on the TV is read from across the room.
    private var isTV: Bool { layout == .tv }

    var body: some View {
        let _ = store.revision
        Menu {
            menuContent
        } label: {
            switch style {
            case .header: headerLabel
            case .sidebar: sidebarLabel
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: style == .sidebar ? .infinity : nil, alignment: .leading)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Switches profile, or opens Household and Settings", bundle: .module))
        .pinFlow($pinRequest) { pin, ids in
            ids.contains { store.verifyPIN(pin, for: $0) }
        }
    }

    private var current: ProfileRecord? { session.currentProfile }

    private var accessibilityLabel: String {
        guard let current else { return String(localized: "Choose a profile", bundle: .module) }
        return String(localized: "Profile: \(current.name)", bundle: .module)
    }

    // MARK: Labels

    /// Mockup 02: a 36-pt avatar, the name in Sora SemiBold 20 and a small
    /// chevron, at least 44 pt tall to touch.
    private var headerLabel: some View {
        HStack(spacing: isTV ? 16 : 10) {
            avatar(size: isTV ? 56 : 36)
                // tvOS fills a focused menu button with the tint, which an
                // amber avatar would vanish into; a dark rim keeps it.
                .overlay {
                    if isTV {
                        RoundedRectangle(cornerRadius: 56 * 0.27, style: .continuous)
                            .strokeBorder(HearthColor.background.opacity(0.55), lineWidth: 3)
                    }
                }
            Text(current?.name ?? String(localized: "Profiles", bundle: .module))
                .font(.hearthDisplay(isTV ? 30 : 20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: isTV ? 20 : 13, weight: .semibold))
                .foregroundStyle(HearthColor.textSecondary)
        }
        .padding(.horizontal, isTV ? 12 : 0)
        .frame(minHeight: isTV ? 76 : HearthMetrics.minimumHitTarget)
        .contentShape(Rectangle())
    }

    /// Mockup 07: a raised card with a 34-pt avatar, the name over the
    /// household's name, and up/down chevrons.
    private var sidebarLabel: some View {
        HStack(spacing: 10) {
            avatar(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(current?.name ?? String(localized: "Profiles", bundle: .module))
                    .font(.hearthText(14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
                Text(store.household.name)
                    .font(.hearthCaption)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HearthColor.textSecondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: HearthMetrics.minimumHitTarget)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HearthColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HearthColor.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func avatar(size: CGFloat) -> some View {
        if let current {
            AvatarTile(name: current.name, palette: current.avatarColor, symbol: current.avatarSymbol, size: size)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(HearthColor.surfaceRaised)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(HearthColor.textSecondary)
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menuContent: some View {
        let others = store.profiles.filter { $0.id != current?.id }
        if !others.isEmpty {
            Section {
                ForEach(others) { profile in
                    Button {
                        switchTo(profile)
                    } label: {
                        Label(profile.name, systemImage: profile.avatarSymbol ?? (profile.hasPIN ? "lock.fill" : "person.crop.circle"))
                        if let detail = menuDetail(for: profile) {
                            Text(detail)
                        }
                    }
                }
            } header: {
                Text("Switch profile", bundle: .module)
            }
        }
        Section {
            Button {
                leaveToGate()
            } label: {
                Label(String(localized: "Who’s watching?", bundle: .module), systemImage: "person.2")
            }
            if session.canManageHousehold, let current {
                Button {
                    openRoute(.profileEditor(profileID: current.id))
                } label: {
                    Label(String(localized: "Edit profile", bundle: .module), systemImage: "pencil")
                }
            }
            if session.canManageHousehold {
                Button {
                    openRoute(.household)
                } label: {
                    Label(String(localized: "Manage household", bundle: .module), systemImage: "house")
                }
            }
            if session.canOpenSettings {
                Button {
                    openRoute(.settings)
                } label: {
                    Label(String(localized: "Settings", bundle: .module), systemImage: "gearshape")
                }
            }
        }
    }

    /// The menu row's second line: the kind and whether a PIN is asked.
    private func menuDetail(for profile: ProfileRecord) -> String? {
        var parts: [String] = []
        switch profile.kind {
        case .kids: parts.append(String(localized: "Kids profile", bundle: .module))
        case .guest: parts.append(String(localized: "Guest", bundle: .module, comment: "Profile kind"))
        case .standard: break
        }
        if profile.hasPIN { parts.append(String(localized: "PIN", bundle: .module, comment: "Menu detail: the profile asks for a PIN")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func switchTo(_ profile: ProfileRecord) {
        let steps = PINSteps.forSwitch(from: current, to: profile, profiles: store.profiles)
        guarded(steps) {
            guard let fresh = store.profiles.first(where: { $0.id == profile.id }) else { return }
            session.select(fresh)
        }
    }

    /// "Who's watching?": back to the gate, past an adult's PIN when leaving a
    /// Kids profile (PRF-4).
    private func leaveToGate() {
        let steps = PINSteps.forSwitch(from: current, to: nil, profiles: store.profiles)
        guarded(steps) { session.signOut() }
    }

    private func guarded(_ steps: [PINStep], action: @escaping @MainActor () -> Void) {
        if steps.isEmpty {
            action()
        } else {
            pinRequest = PINFlowRequest(steps: steps, perform: action)
        }
    }
}

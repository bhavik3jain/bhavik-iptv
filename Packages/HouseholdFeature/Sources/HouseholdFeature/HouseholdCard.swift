import Core
import HouseholdKit
import SwiftUI

/// The first card on Household (mockup 05): the household's name and how it
/// is shared, its members with their roles, Invite for the owner (HH-2) and
/// Leave for everyone else (HH-4).
struct HouseholdCard: View {
    @Environment(HouseholdStore.self) private var store

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var invitation: CloudShareInvitation?
    @State private var isPreparingShare = false
    @State private var shareError: HouseholdShareError?
    @State private var isConfirmingLeave = false
    @State private var isLeaving = false
    @State private var memberToRemove: MemberRecord?
    @State private var actionError: String?

    private var household: HouseholdInfo { store.household }
    private var isOwner: Bool { household.currentRole == .owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            members
            if isOwner {
                inviteButton
            } else {
                leaveButton
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                .fill(HearthColor.surface)
        )
        .alert(String(localized: "Rename household"), isPresented: $isRenaming) {
            TextField(String(localized: "Name"), text: $draftName)
            Button(String(localized: "Save")) {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.renameHousehold(name) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Everyone in the household sees the new name.")
        }
        .alert(shareError?.title ?? "", isPresented: isShowing($shareError), presenting: shareError) { error in
            switch error {
            case .iCloudUnavailable, .noHousehold, .notOwner:
                Button(String(localized: "OK"), role: .cancel) {}
            default:
                if error.offersShareAnyway {
                    Button(String(localized: "Share Anyway")) { invite(ignoringEarlierTries: true) }
                    Button(String(localized: "Check Again")) { invite() }
                } else {
                    Button(String(localized: "Try Again")) { invite() }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
        } message: { error in
            Text(error.errorDescription ?? "")
        }
        .alert(String(localized: "Something went wrong"), isPresented: isShowing($actionError), presenting: actionError) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            String(localized: "Leave \(household.name)?"),
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Leave Household"), role: .destructive) { leave() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Its profiles, sources, favorites and progress leave all of your devices. Everyone else keeps everything, and the owner can invite you again.")
        }
        .confirmationDialog(
            String(localized: "Remove \(memberToRemove?.displayName ?? "")?"),
            isPresented: isShowing($memberToRemove),
            titleVisibility: .visible,
            presenting: memberToRemove
        ) { member in
            Button(String(localized: "Remove from Household"), role: .destructive) { remove(member) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("They stop seeing the household's profiles and sources on their devices. Their own favorites and progress go with it.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            CardTile(systemName: "house")
            VStack(alignment: .leading, spacing: 1) {
                Text(household.name)
                    .font(.hearthDisplay(18, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(HearthColor.textPrimary)
                Text(MemberText.householdLine(isShared: household.isShared, memberCount: store.members.count))
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if isOwner {
                Button {
                    draftName = household.name
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HearthColor.textSecondary)
                        .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hearthTile)
                .accessibilityLabel(Text("Rename household"))
            }
        }
    }

    // MARK: Members

    private var members: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 {
                    Rectangle()
                        .fill(HearthColor.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                memberRow(member)
            }
        }
    }

    private func memberRow(_ member: MemberRecord) -> some View {
        HStack(spacing: 12) {
            AvatarCircle(name: member.displayName, palette: MemberText.palette(for: member))
                .accessibilityHidden(true)
            Group {
                if member.isCurrentUser {
                    Text("\(member.displayName) \(Text("(you)").foregroundStyle(HearthColor.textSecondary))")
                } else {
                    Text(member.displayName)
                }
            }
            .font(.hearthBody)
            .foregroundStyle(HearthColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if isOwner, member.role != .owner, !member.isCurrentUser {
                roleMenu(for: member)
            } else {
                Text(MemberText.role(member.role))
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    /// The owner changes a member's role, or takes them off the share (HH-4,
    /// SRC-8). Roles are the app's; iCloud gives everyone read and write.
    private func roleMenu(for member: MemberRecord) -> some View {
        Menu {
            Picker(
                String(localized: "Role"),
                selection: Binding(
                    get: { member.role },
                    set: { store.setRole($0, forParticipant: member.id) }
                )
            ) {
                ForEach([MemberRole.manage, .watch], id: \.self) { role in
                    Text(MemberText.role(role)).tag(role)
                }
            }
            .pickerStyle(.inline)
            Section {
                Button(String(localized: "Remove from Household"), systemImage: "person.badge.minus", role: .destructive) {
                    memberToRemove = member
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(MemberText.role(member.role))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.hearthFootnote)
            .foregroundStyle(HearthColor.textSecondary)
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text("Role for \(member.displayName)"))
        .accessibilityValue(Text(MemberText.role(member.role)))
    }

    // MARK: Invite and leave

    private var inviteButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                invite()
            } label: {
                HStack(spacing: 8) {
                    if isPreparingShare {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HearthColor.textPrimary)
                        Text(store.sharePreparationStatus ?? String(localized: "Getting the invitation ready…"))
                    } else {
                        Image(systemName: "person.badge.plus")
                            .accessibilityHidden(true)
                        Text("Invite someone")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))
            .disabled(isPreparingShare)
            .cloudSharingSheet(invitation: $invitation) {
                store.refreshShareStatus()
            }
            .accessibilityHint(Text("Opens iCloud sharing to send an invitation by Messages, Mail or a link"))
            Text("People you invite start as Can watch. Change their role here once they join.")
                .font(.hearthCaption)
                .foregroundStyle(HearthColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var leaveButton: some View {
        Button(role: .destructive) {
            isConfirmingLeave = true
        } label: {
            HStack(spacing: 8) {
                if isLeaving {
                    ProgressView().controlSize(.small).tint(HearthColor.danger)
                    Text("Leaving…")
                } else {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .accessibilityHidden(true)
                    Text("Leave household")
                }
            }
            .foregroundStyle(HearthColor.danger)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))
        .disabled(isLeaving)
    }

    /// Asks HouseholdKit for the saved share (bounded, off the main thread),
    /// then hands it to the system sharing UI. A failure says why, with
    /// Share Anyway when an earlier try left a copy in iCloud.
    private func invite(ignoringEarlierTries: Bool = false) {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            do {
                let prepared = try await store.prepareShare(ignoringEarlierTries: ignoringEarlierTries)
                invitation = CloudShareInvitation(share: prepared.share, container: prepared.container)
            } catch let error as HouseholdShareError {
                shareError = error
            } catch {
                shareError = .failed(error.localizedDescription)
            }
        }
    }

    private func leave() {
        isLeaving = true
        Task {
            defer { isLeaving = false }
            do {
                try await store.leaveHousehold()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func remove(_ member: MemberRecord) {
        Task {
            do {
                try await store.removeMember(participantID: member.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// A Bool binding for "an optional is set", for alerts and dialogs that
/// present a value.
func isShowing<Value: Sendable>(_ value: Binding<Value?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { if !$0 { value.wrappedValue = nil } }
    )
}

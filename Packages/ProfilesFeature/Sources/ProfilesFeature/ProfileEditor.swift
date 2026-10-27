import Core
import HouseholdKit
import SwiftUI

extension EnvironmentValues {
    /// True when the editor sits in a sheet of its own (from the profile
    /// gate), which gives it a Cancel button. Pushed by the app it has the
    /// back button instead.
    @Entry var profileEditorInSheet = false
}

/// The profile gate's editor sheet: the editor in a navigation stack of its
/// own (for the category pickers it pushes), form-sized on the Mac and iPad.
struct ProfileEditorSheet: View {
    let profileID: UUID?

    var body: some View {
        NavigationStack {
            ProfileEditorScreen(profileID: profileID)
        }
        .environment(\.profileEditorInSheet, true)
        .presentationSizing(.form)
        .presentationBackground(HearthColor.background)
        .preferredColorScheme(.dark)
        .tint(HearthColor.accent)
    }
}

/// Creates (nil) or edits a profile (PRF-1, PRF-3, PRF-4, PRF-5, PRF-6):
/// a live preview of the avatar; name; colour and symbol; kind; PIN; for
/// Kids the allowed categories; which sources show and which categories are
/// hidden; preferred languages; Delete.
///
/// Everything is edited on a `ProfileDraft` and written on Save: the
/// profile with `addProfile`/`updateProfile`, then the PIN with `setPIN`.
/// A member who may not manage sees the profile read-only (the store would
/// refuse the write anyway).
struct ProfileEditorScreen: View {
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.profileEditorInSheet) private var inSheet

    @State private var draft: ProfileDraft?
    @State private var initialDraft: ProfileDraft?
    /// A new profile once its first Save created it, so a Save retried after
    /// a failed follow-up write updates it rather than adding a second one.
    @State private var createdID: UUID?
    /// Set on Save or Delete, so the screen doesn't flash "household full"
    /// or "profile gone" while it is going away.
    @State private var isFinished = false
    @State private var showsPINSetup = false
    @State private var confirmsDelete = false
    @State private var confirmsGuest = false
    @State private var saveError: String?
    /// "Open at launch on this device" (PRF-2). A setting of this device's,
    /// not of the profile, so it lives outside the draft; staged the same way
    /// and applied on Save.
    @State private var opensHere = false
    @State private var initialOpensHere = false
    @FocusState private var nameIsFocused: Bool

    private var editedID: UUID? { profileID ?? createdID }

    private var original: ProfileRecord? {
        editedID.flatMap { id in store.profiles.first { $0.id == id } }
    }

    private var canManage: Bool { session.canManageHousehold }
    private var isDirty: Bool { draft != initialDraft || opensHere != initialOpensHere }

    var body: some View {
        let _ = store.revision
        content
            .navigationTitle(profileID == nil ? String(localized: "New profile", bundle: .module) : String(localized: "Edit profile", bundle: .module))
            .inlineNavigationTitle()
            .toolbar { toolbar }
            .hearthScreenBackground()
            .tint(HearthColor.accent)
            .interactiveDismissDisabled(inSheet && isDirty)
            .onAppear(perform: loadDraft)
            // Opened before the profile reached this device (a link followed
            // while iCloud is still importing): fill in once it arrives.
            .onChange(of: store.revision) { loadDraft() }
            .sheet(isPresented: $showsPINSetup) {
                PINSetupSheet(
                    profileName: draft?.trimmedName ?? "",
                    onDone: { pin in
                        draft?.pinChange = .set(pin)
                        showsPINSetup = false
                    },
                    onCancel: { showsPINSetup = false }
                )
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button(role: .destructive, action: delete) {
                    Text("Delete profile", bundle: .module)
                }
            } message: {
                Text("Its favorites, My List and progress are deleted too, on every device in the household.", bundle: .module)
            }
            .confirmationDialog(guestTitle, isPresented: $confirmsGuest, titleVisibility: .visible) {
                Button(role: .destructive) {
                    save(confirmedGuest: true)
                } label: {
                    Text("Make it a Guest", bundle: .module)
                }
            } message: {
                Text("Guests keep nothing, so this profile’s favorites, My List and progress are deleted from every device.", bundle: .module)
            }
            .alert(
                Text("Couldn’t save the profile", bundle: .module),
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button(role: .cancel) {
                    saveError = nil
                } label: {
                    Text("OK", bundle: .module)
                }
            } message: {
                Text(saveError ?? "")
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if isFinished {
            Color.clear
        } else if profileID != nil, original == nil {
            EmptyStateView(
                systemName: "person.crop.circle.badge.xmark",
                title: String(localized: "This profile is gone", bundle: .module),
                message: String(localized: "It was deleted, perhaps on another device.", bundle: .module)
            )
            .frame(maxHeight: .infinity)
        } else if editedID == nil, !ProfileEditRules.canAdd(profileCount: store.profiles.count) {
            EmptyStateView(
                systemName: "person.3.fill",
                title: String(localized: "This household is full", bundle: .module),
                message: String(localized: "A household can have up to \(ProfileEditRules.maxProfiles) profiles. Delete one to add another.", bundle: .module)
            )
            .frame(maxHeight: .infinity)
        } else if let binding = Binding($draft) {
            form(binding)
        } else {
            Color.clear
        }
    }

    private func loadDraft() {
        guard draft == nil else { return }
        if let original {
            draft = ProfileDraft(record: original)
        } else if profileID == nil {
            draft = ProfileDraft.new(existing: store.profiles)
            // The name field only exists once the form draws with the new
            // draft, and a sheet is still sliding in: focus it a beat later,
            // or the request lands on nothing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                nameIsFocused = true
            }
        }
        initialDraft = draft
        opensHere = profileID != nil && session.alwaysOpenProfileID == profileID
        initialOpensHere = opensHere
    }

    // MARK: Form

    private func form(_ draft: Binding<ProfileDraft>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing) {
                preview(draft.wrappedValue)
                if !canManage {
                    readOnlyNotice
                }
                Group {
                    nameSection(draft)
                    avatarSection(draft)
                    kindSection(draft)
                    pinSection(draft)
                    if draft.wrappedValue.kind == .kids {
                        kidsSection(draft)
                    }
                    seesSection(draft)
                    languagesSection(draft)
                    deviceSection(draft.wrappedValue)
                    deleteSection
                }
                .disabled(!canManage)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The avatar as it will look, with the name and kind under it.
    private func preview(_ draft: ProfileDraft) -> some View {
        let name = draft.trimmedName
        let hasPIN = draft.willHavePIN(hadPIN: original?.hasPIN ?? false)
        return VStack(spacing: 10) {
            AvatarTile(name: name.isEmpty ? "?" : name, palette: draft.avatarColor, symbol: draft.avatarSymbol, size: 88, isLocked: hasPIN)
            Text(name.isEmpty ? String(localized: "New profile", bundle: .module) : name)
                .font(.hearthHeadline)
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(draft.kind.title)
                if hasPIN {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityLabel(Text("Locked with a PIN", bundle: .module))
                }
            }
            .font(.hearthCaption)
            .foregroundStyle(HearthColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var readOnlyNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(HearthColor.accent)
                .accessibilityHidden(true)
            Text("Only the household’s owner or a manager can change profiles.", bundle: .module)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HearthMetrics.controlRadius, style: .continuous).fill(HearthColor.surface))
        .accessibilityElement(children: .combine)
    }

    // MARK: Name

    private func nameSection(_ draft: Binding<ProfileDraft>) -> some View {
        GroupedCard(title: String(localized: "Name", bundle: .module)) {
            TextField(
                String(localized: "Name", bundle: .module),
                text: draft.name,
                prompt: Text("Profile name", bundle: .module).foregroundStyle(HearthColor.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(.hearthBody)
            .foregroundStyle(HearthColor.textPrimary)
            .focused($nameIsFocused)
            .submitLabel(.done)
            .frame(minHeight: 48)
            .onChange(of: draft.wrappedValue.name) { _, name in
                if name.count > ProfileDraft.maxNameLength {
                    draft.wrappedValue.name = String(name.prefix(ProfileDraft.maxNameLength))
                }
            }
        }
    }

    // MARK: Avatar (PRF-1)

    private func avatarSection(_ draft: Binding<ProfileDraft>) -> some View {
        GroupedCard(title: String(localized: "Avatar", bundle: .module)) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                ForEach(AvatarPalette.allCases, id: \.self) { palette in
                    colorSwatch(palette, draft: draft)
                }
            }
            .padding(.vertical, 14)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Colour", bundle: .module))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                symbolCell(nil, draft: draft)
                ForEach(AvatarSymbols.all, id: \.self) { symbol in
                    symbolCell(symbol, draft: draft)
                }
            }
            .padding(.vertical, 14)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Letter or symbol", bundle: .module))
        }
    }

    private func colorSwatch(_ palette: AvatarPalette, draft: Binding<ProfileDraft>) -> some View {
        let isSelected = draft.wrappedValue.avatarColor == palette
        return Button {
            draft.wrappedValue.avatarColor = palette
        } label: {
            Circle()
                .fill(palette.fill)
                .frame(width: 34, height: 34)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(palette.ink)
                    }
                }
                .padding(4)
                .overlay(Circle().strokeBorder(isSelected ? HearthColor.textPrimary : Color.clear, lineWidth: 2))
                .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.hearthTile)
        .accessibilityLabel(Text(palette.spokenName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A symbol, or the profile's initial when `symbol` is nil.
    private func symbolCell(_ symbol: String?, draft: Binding<ProfileDraft>) -> some View {
        let value = draft.wrappedValue
        let isSelected = value.avatarSymbol == symbol
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            draft.wrappedValue.avatarSymbol = symbol
        } label: {
            shape
                .fill(isSelected ? value.avatarColor.fill : HearthColor.surfaceRaised)
                .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                .overlay {
                    Group {
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 18, weight: .semibold))
                        } else {
                            Text(Monogram.initials(for: value.trimmedName.isEmpty ? "A" : value.trimmedName, maxLetters: 1))
                                .font(.hearth(.display, fixedSize: 19, weight: .bold))
                        }
                    }
                    .foregroundStyle(isSelected ? value.avatarColor.ink : HearthColor.textPrimary)
                }
                .contentShape(shape)
        }
        .buttonStyle(.hearthTile)
        .accessibilityLabel(Text(symbol.map(AvatarSymbols.spokenName) ?? String(localized: "Initial", bundle: .module)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Kind (PRF-1, PRF-4, PRF-5)

    private func kindSection(_ draft: Binding<ProfileDraft>) -> some View {
        let kinds = ProfileEditRules.kinds(for: editedID, in: store.profiles)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "Type", bundle: .module))
                .padding(.horizontal, 4)
            if kinds.count > 1 {
                SegmentedPills(String(localized: "Profile type", bundle: .module), options: kinds, selection: draft.kind) { $0.title }
            }
            Text(kinds.count > 1
                 ? draft.wrappedValue.kind.explanation
                 : String(localized: "This is the household’s only standard profile, so it stays standard.", bundle: .module))
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: PIN (PRF-3)

    private func pinSection(_ draft: Binding<ProfileDraft>) -> some View {
        let hadPIN = original?.hasPIN ?? false
        let hasPIN = draft.wrappedValue.willHavePIN(hadPIN: hadPIN)
        let footer: String = switch draft.wrappedValue.pinChange {
        case .set: String(localized: "The new PIN is saved when you tap Save.", bundle: .module)
        case .remove: String(localized: "The PIN is removed when you tap Save.", bundle: .module)
        case .unchanged: String(localized: "Asked whenever someone switches to this profile. The owner or a manager can remove a forgotten PIN here.", bundle: .module)
        }
        return GroupedCard(title: String(localized: "PIN", bundle: .module), footer: footer) {
            Button {
                showsPINSetup = true
            } label: {
                CardRow(
                    hasPIN ? String(localized: "Change PIN", bundle: .module) : String(localized: "Set a PIN", bundle: .module),
                    trailingText: hasPIN ? String(localized: "On", bundle: .module) : String(localized: "Off", bundle: .module),
                    showsChevron: true
                ) {
                    CardTile(systemName: hasPIN ? "lock.fill" : "lock.open.fill", size: 34)
                }
            }
            .buttonStyle(.hearthTile)
            if hasPIN {
                Button(role: .destructive) {
                    // Undoing a PIN chosen in this session just forgets it.
                    draft.wrappedValue.pinChange = hadPIN ? .remove : .unchanged
                } label: {
                    HStack {
                        Text("Remove PIN", bundle: .module)
                            .font(.hearthBody)
                            .foregroundStyle(HearthColor.danger)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hearthTile)
            }
        }
    }

    // MARK: Kids (PRF-4)

    private func kidsSection(_ draft: Binding<ProfileDraft>) -> some View {
        let count = draft.wrappedValue.allowedCategoryKeys.count
        let summary = switch count {
        case 0: String(localized: "None yet, so this profile shows nothing", bundle: .module)
        case 1: String(localized: "1 category", bundle: .module)
        default: String(localized: "\(count) categories", bundle: .module)
        }
        return GroupedCard(
            title: String(localized: "Kids can watch", bundle: .module),
            footer: String(localized: "Only these categories show on this profile. Adult categories never do.", bundle: .module)
        ) {
            NavigationLink {
                CategoryRulesView(mode: .allowed, selection: draft.allowedCategoryKeys)
            } label: {
                CardRow(String(localized: "Allowed categories", bundle: .module), subtitle: summary, showsChevron: true) {
                    CardTile(systemName: count == 0 ? "exclamationmark.triangle.fill" : "checklist", size: 34)
                }
            }
            .buttonStyle(.hearthTile)
        }
    }

    // MARK: Sources and hidden categories (PRF-6, LIV-8)

    @ViewBuilder
    private func seesSection(_ draft: Binding<ProfileDraft>) -> some View {
        let sources = store.sources
        let allIDs = sources.map(\.id)
        let showsSources = sources.count > 1
        let showsHidden = draft.wrappedValue.kind != .kids
        if showsSources || showsHidden {
            GroupedCard(
                title: String(localized: "What this profile sees", bundle: .module),
                footer: showsSources
                    ? String(localized: "A source added later shows on every profile until you turn it off here.", bundle: .module)
                    : nil
            ) {
                if showsSources {
                    ForEach(sources) { source in
                        let visible = draft.wrappedValue.visibleSourceIDs
                        CardToggleRow(
                            source.name,
                            subtitle: sourceKindTitle(source.kindRaw),
                            isOn: Binding(
                                get: { SourceVisibility.isVisible(source.id, in: draft.wrappedValue.visibleSourceIDs) },
                                set: { isOn in
                                    draft.wrappedValue.visibleSourceIDs = SourceVisibility.toggled(
                                        source.id, isOn: isOn, visible: draft.wrappedValue.visibleSourceIDs, allSourceIDs: allIDs
                                    )
                                }
                            )
                        )
                        .disabled(!SourceVisibility.canHide(source.id, visible: visible, allSourceIDs: allIDs))
                    }
                }
                if showsHidden {
                    let count = draft.wrappedValue.hiddenCategoryKeys.count
                    NavigationLink {
                        CategoryRulesView(mode: .hidden, selection: draft.hiddenCategoryKeys)
                    } label: {
                        CardRow(
                            String(localized: "Hidden categories", bundle: .module),
                            subtitle: count == 0
                                ? String(localized: "None hidden", bundle: .module)
                                : String(localized: "\(count) hidden", bundle: .module),
                            showsChevron: true
                        ) {
                            CardTile(systemName: "eye.slash.fill", size: 34)
                        }
                    }
                    .buttonStyle(.hearthTile)
                }
            }
        }
    }

    private func sourceKindTitle(_ kindRaw: String) -> String {
        switch kindRaw {
        case "stalker": String(localized: "Portal", bundle: .module)
        case "xtream": String(localized: "Xtream login", bundle: .module)
        case "m3u": String(localized: "Playlist", bundle: .module)
        default: kindRaw
        }
    }

    // MARK: Languages (PLY-6)

    private func languagesSection(_ draft: Binding<ProfileDraft>) -> some View {
        let options = LanguageOptions.options(keeping: [draft.wrappedValue.audioLanguage, draft.wrappedValue.subtitleLanguage])
        return GroupedCard(
            title: String(localized: "Languages", bundle: .module),
            footer: String(localized: "Picked when a stream offers a choice of audio or subtitles.", bundle: .module)
        ) {
            languageRow(String(localized: "Audio", bundle: .module), selection: draft.audioLanguage, options: options)
            languageRow(String(localized: "Subtitles", bundle: .module), selection: draft.subtitleLanguage, options: options)
        }
    }

    private func languageRow(_ title: String, selection: Binding<String?>, options: [LanguageOptions.Option]) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.hearthBody)
                .foregroundStyle(HearthColor.textPrimary)
            Spacer(minLength: 8)
            Picker(selection: selection) {
                Text("No preference", bundle: .module).tag(String?.none)
                Divider()
                ForEach(options) { option in
                    Text(option.name).tag(Optional(option.code))
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(HearthColor.accent)
        }
        .frame(minHeight: 48)
    }

    // MARK: This device (PRF-2)

    private func deviceSection(_ draft: ProfileDraft) -> some View {
        let footer = draft.willHavePIN(hadPIN: original?.hasPIN ?? false)
            ? String(localized: "Skips “Who’s watching?” on this device, without asking for the PIN. Other devices still ask.", bundle: .module)
            : String(localized: "Skips “Who’s watching?” on this device. Other devices still ask.", bundle: .module)
        return GroupedCard(title: String(localized: "This device", bundle: .module), footer: footer) {
            CardToggleRow(String(localized: "Open this profile at launch", bundle: .module), isOn: $opensHere)
        }
    }

    // MARK: Delete

    @ViewBuilder
    private var deleteSection: some View {
        if let original {
            if ProfileEditRules.canDelete(original.id, in: store.profiles) {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Text("Delete profile", bundle: .module)
                        .foregroundStyle(HearthColor.danger)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))
            } else if ProfileEditRules.isLastStandard(original.id, in: store.profiles) {
                Text("The household’s only standard profile can’t be deleted.", bundle: .module)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var deleteTitle: Text {
        Text("Delete \(original?.name ?? "")?", bundle: .module)
    }

    private var guestTitle: Text {
        Text("Make \(original?.name ?? "") a Guest?", bundle: .module)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if inSheet {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                save()
            } label: {
                Text(editedID == nil ? String(localized: "Add", bundle: .module) : String(localized: "Save", bundle: .module))
                    .fontWeight(.semibold)
            }
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        guard canManage, !isFinished, let draft, draft.isValid else { return false }
        return editedID == nil || original != nil
    }

    // MARK: Saving

    private func save(confirmedGuest: Bool = false) {
        guard canSave, let draft else { return }
        if let original, original.kind != .guest, draft.kind == .guest, !confirmedGuest {
            confirmsGuest = true
            return
        }
        let errorBefore = store.lastWriteError
        let id: UUID
        if let original {
            let updated = draft.applied(to: original)
            if updated != original { store.updateProfile(updated) }
            id = original.id
        } else {
            guard ProfileEditRules.canAdd(profileCount: store.profiles.count),
                  let created = store.addProfile(name: draft.trimmedName, kind: draft.kind, avatarColor: draft.avatarColor, avatarSymbol: draft.avatarSymbol)
            else {
                saveError = store.lastWriteError
                    ?? String(localized: "A household can have up to \(ProfileEditRules.maxProfiles) profiles.", bundle: .module)
                return
            }
            createdID = created.id
            // Rules and languages go in a second write, and only when the
            // new profile has any.
            let updated = draft.applied(to: created)
            if updated != created { store.updateProfile(updated) }
            id = created.id
        }
        switch draft.pinChange {
        case .unchanged: break
        case .set(let pin): store.setPIN(pin, for: id)
        case .remove: store.setPIN(nil, for: id)
        }
        if let error = store.lastWriteError, error != errorBefore {
            saveError = error
            return
        }
        if opensHere {
            session.alwaysOpenProfileID = id
        } else if session.alwaysOpenProfileID == id {
            session.alwaysOpenProfileID = nil
        }
        // The open profile may be the one edited: its new kind, PIN or rules
        // take effect now.
        session.refresh()
        isFinished = true
        dismiss()
    }

    private func delete() {
        guard let original else { return }
        store.deleteProfile(id: original.id)
        if session.alwaysOpenProfileID == original.id {
            session.alwaysOpenProfileID = nil
        }
        session.refresh()
        isFinished = true
        dismiss()
    }
}

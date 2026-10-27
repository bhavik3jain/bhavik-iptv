import Core
import SwiftUI

/// The 4-digit PIN pad behind `PINEntryView` and every PIN sheet in this
/// package (PRF-3, PRF-4): a header, the title, four dots and a phone-style
/// number pad with Cancel and delete in the bottom row.
///
/// The owner answers each complete PIN with a `PINPadOutcome`; the pad does
/// the rest (`PINEntryState`): a wrong PIN shakes the dots (they only turn
/// red under Reduce Motion), clears and says so, and five wrong tries pause
/// the pad for half a minute. Digits, Delete and Escape work from a hardware
/// keyboard (the Mac, an iPad with a keyboard) through `.onKeyPress`.
struct PINPad<Header: View>: View {
    let title: String
    let message: String?
    let messageIsError: Bool
    let onSubmit: (String) -> PINPadOutcome
    let onCancel: (() -> Void)?
    let header: Header

    init(
        title: String,
        message: String? = nil,
        messageIsError: Bool = false,
        onSubmit: @escaping (String) -> PINPadOutcome,
        onCancel: (() -> Void)?,
        @ViewBuilder header: () -> Header
    ) {
        self.title = title
        self.message = message
        self.messageIsError = messageIsError
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.header = header()
    }

    @State private var state = PINEntryState()
    @FocusState private var hasKeyboardFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hearthLayout) private var layout
    /// Keys grow with Dynamic Type, up to a size that still fits four rows on
    /// iPhone Duo's inner display.
    @ScaledMetric(relativeTo: .title) private var scaledKeySize: CGFloat = 74

    /// The TV's keys are pressed with the remote's focus, from across the room.
    private var isTV: Bool { layout == .tv }
    private var keySize: CGFloat { isTV ? 116 : min(max(scaledKeySize, 64), 92) }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 26) {
                    header
                    titleBlock
                    dots
                    keypad
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: isTV ? 640 : 420)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // `.edit`: the pad takes typed input, as a text field would, so a
        // hardware keyboard reaches it without a focus ring on every key.
        // A hardware keyboard types digits here; on the TV the keys themselves
        // take focus, so the pad must not.
        .focusable(!isTV, interactions: .edit)
        .focused($hasKeyboardFocus)
        .defaultFocus($hasKeyboardFocus, true)
        .focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let digit = press.characters.first, digit.isASCII else { return .ignored }
            type(digit)
            return .handled
        }
        .onKeyPress(.delete) {
            state.deleteLast()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            state.deleteLast()
            return .handled
        }
        .onAppear { hasKeyboardFocus = true }
        .sensoryFeedback(.error, trigger: state.shakes)
        .sensoryFeedback(.success, trigger: state.phase == .accepted)
        .task(id: state.lockedUntil) {
            // Ends the cooldown when it runs out; the TimelineView in the
            // message counts it down meanwhile.
            guard let until = state.lockedUntil else { return }
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            state.endCooldown()
        }
    }

    // MARK: Title and message

    private var titleBlock: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(isTV ? .hearthTVTitle : .hearthDisplay(22, weight: .semibold, relativeTo: .title2))
                .tracking(-0.3)
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                messageLine(at: context.date)
            }
        }
    }

    @ViewBuilder
    private func messageLine(at date: Date) -> some View {
        let line: (text: String, isError: Bool)? = {
            if let seconds = state.secondsLeft(at: date) {
                return (String(localized: "Too many tries. Try again in \(seconds) s.", bundle: .module), true)
            }
            if state.showsWrongPIN {
                return (String(localized: "Wrong PIN. Try again.", bundle: .module), true)
            }
            return message.map { ($0, messageIsError) }
        }()
        // Always takes room for two lines' worth, so the dots don't jump when
        // a message comes and goes.
        Text(line?.text ?? " ")
            .font(isTV ? .hearthTVCallout : .hearthFootnote)
            .foregroundStyle(line?.isError == true ? HearthColor.danger : HearthColor.textSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 34, alignment: .top)
            .accessibilityHidden(line == nil)
    }

    // MARK: Dots

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<PINEntryState.length, id: \.self) { index in
                let filled = index < state.digits.count || state.phase == .accepted
                Circle()
                    .fill(filled ? dotColor : Color.clear)
                    .overlay(Circle().strokeBorder(filled ? Color.clear : dotStroke, lineWidth: 1.5))
                    .frame(width: isTV ? 24 : 14, height: isTV ? 24 : 14)
            }
        }
        .frame(minHeight: 24)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: state.shakes) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            // A short side-to-side shake; none under Reduce Motion, where
            // the red dots and the message carry the news instead.
            let travel: CGFloat = reduceMotion ? 0 : 12
            KeyframeTrack {
                LinearKeyframe(travel, duration: 0.06)
                LinearKeyframe(-travel, duration: 0.08)
                LinearKeyframe(travel * 0.6, duration: 0.08)
                LinearKeyframe(-travel * 0.4, duration: 0.07)
                SpringKeyframe(0, duration: 0.15)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("PIN", bundle: .module))
        .accessibilityValue(Text("\(state.digits.count) of \(PINEntryState.length) digits entered", bundle: .module))
    }

    private var dotColor: Color {
        state.showsWrongPIN && reduceMotion ? HearthColor.danger : HearthColor.accent
    }

    private var dotStroke: Color {
        state.showsWrongPIN ? HearthColor.danger : HearthColor.dashedStroke
    }

    // MARK: Keypad

    private typealias Key = PINPadKey

    private var keypad: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let enabled = state.canType(at: context.date)
            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                ForEach(PINPadKey.rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { key in
                            keyView(key, enabled: enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: Key, enabled: Bool) -> some View {
        switch key {
        case .digit(let value):
            Button {
                type(Character(String(value)))
            } label: {
                Text(verbatim: String(value))
                    .font(.hearth(.display, fixedSize: keySize * 0.38, weight: .regular))
                    .monospacedDigit()
            }
            .buttonStyle(PINKeyButtonStyle(size: keySize))
            .disabled(!enabled)
            .accessibilityLabel(Text(verbatim: String(value)))
        case .cancel:
            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                        .font(.hearthText(isTV ? 26 : 16, weight: .medium, relativeTo: .body))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(HearthColor.textPrimary)
                        .frame(width: keySize, height: keySize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hearthTile)
                .hearthCancelShortcut()
            } else {
                Color.clear.frame(width: keySize, height: keySize)
            }
        case .delete:
            let hasDigits = !state.digits.isEmpty && state.phase == .entering
            Button {
                state.deleteLast()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: keySize * 0.3, weight: .regular))
                    .foregroundStyle(HearthColor.textPrimary)
                    .frame(width: keySize, height: keySize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hearthTile)
            .opacity(hasDigits ? 1 : 0)
            .disabled(!hasDigits)
            .accessibilityHidden(!hasDigits)
            .accessibilityLabel(Text("Delete", bundle: .module))
        }
    }

    // MARK: Typing

    private func type(_ digit: Character) {
        guard let pin = state.append(digit) else { return }
        Task { @MainActor in
            // Lets the fourth dot fill before the answer.
            try? await Task.sleep(for: .milliseconds(140))
            let outcome = onSubmit(pin)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                state.resolve(outcome)
            }
            if outcome == .rejected {
                AccessibilityNotification.Announcement(String(localized: "Wrong PIN", bundle: .module)).post()
            }
        }
    }
}

/// A key of the pad, laid out as a phone's: digits, then Cancel, 0 and
/// delete along the bottom.
private enum PINPadKey: Hashable {
    case digit(Int)
    case cancel
    case delete

    static let rows: [[PINPadKey]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.cancel, .digit(0), .delete],
    ]
}

/// A round number key: raised dark disc, lighter while pressed. 74 pt by
/// default, never under 64, so it is comfortably above the 44-pt minimum.
private struct PINKeyButtonStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PINKeyBody(configuration: configuration, size: size)
    }
}

private struct PINKeyBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    /// The remote's focus on the TV (a keyboard's elsewhere): amber, lifted.
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? HearthColor.onAccent : HearthColor.textPrimary)
            .frame(width: size, height: size)
            .background(
                Circle().fill(fill)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .contentShape(Circle())
    }

    private var fill: Color {
        if isFocused { return HearthColor.accent }
        return configuration.isPressed ? HearthColor.dashedStroke : HearthColor.surfaceRaised
    }
}

/// A PIN pad on its own sheet, walking through one or more `PINStep`s (an
/// adult's PIN, then the profile's), with the avatar of the profile being
/// opened above the pad.
struct PINStepsSheet: View {
    let steps: [PINStep]
    let verify: (String, [UUID]) -> Bool
    let onPassed: () -> Void
    let onCancel: () -> Void

    @State private var index = 0

    var body: some View {
        if steps.isEmpty {
            // Callers run the action directly when no PIN is needed; this
            // only guards against a sheet with nothing to ask.
            Color.clear.onAppear(perform: onPassed)
        } else {
            pad(for: steps[min(index, steps.count - 1)])
        }
    }

    private func pad(for step: PINStep) -> some View {
        PINPad(
            title: step.title,
            message: step.message,
            onSubmit: { pin in
                guard verify(pin, step.profileIDs) else { return .rejected }
                if index + 1 < steps.count {
                    index += 1
                    return .next
                }
                onPassed()
                return .accepted
            },
            onCancel: onCancel
        ) {
            PINStepHeader(step: step)
        }
        .pinSheetChrome()
    }
}

/// The picture above a PIN pad: the avatar of the profile being opened, or a
/// lock for an adult's PIN.
struct PINStepHeader: View {
    let step: PINStep

    var body: some View {
        if let profile = step.avatar {
            AvatarTile(name: profile.name, palette: profile.avatarColor, symbol: profile.avatarSymbol, size: 76, isLocked: profile.hasPIN)
                .accessibilityHidden(true)
        } else {
            PINLockGlyph()
        }
    }
}

/// An amber lock on a raised rounded square, over pads that open no
/// particular profile.
struct PINLockGlyph: View {
    var body: some View {
        CardTile(systemName: "lock.fill", size: 64)
    }
}

extension View {
    /// How every PIN sheet presents: the app background edge to edge, sized
    /// to the pad on the Mac and iPad, a full sheet on the phone.
    func pinSheetChrome() -> some View {
        self
            .frame(idealWidth: 400, idealHeight: 660)
            .hearthScreenBackground()
            .presentationSizing(.fitted)
            .presentationBackground(HearthColor.background)
            .preferredColorScheme(.dark)
    }
}

/// A request to run some PIN steps and then do something.
struct PINFlowRequest: Identifiable {
    let id = UUID()
    let steps: [PINStep]
    let perform: @MainActor () -> Void
}

/// Presents a `PINFlowRequest` as a sheet and runs its action once the PINs
/// pass and the sheet has gone: an action that replaces the screen (picking a
/// profile swaps the gate for Home) must not run under a sheet still on it.
private struct PINFlowPresenter: ViewModifier {
    @Binding var request: PINFlowRequest?
    let verify: (String, [UUID]) -> Bool
    @State private var passed: PINFlowRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request, onDismiss: {
            guard let passed else { return }
            self.passed = nil
            passed.perform()
        }) { request in
            PINStepsSheet(
                steps: request.steps,
                verify: verify,
                onPassed: {
                    passed = request
                    self.request = nil
                },
                onCancel: { self.request = nil }
            )
        }
    }
}

extension View {
    /// Shows the PIN sheet for `request` and runs its action once it passes.
    /// `verify` answers whether a PIN opens any of the given profiles.
    func pinFlow(_ request: Binding<PINFlowRequest?>, verify: @escaping (String, [UUID]) -> Bool) -> some View {
        modifier(PINFlowPresenter(request: request, verify: verify))
    }
}

/// Choosing a new PIN for a profile: type it, then again to confirm
/// (`PINSetupState`). Hands the PIN back only when both entries match.
struct PINSetupSheet: View {
    let profileName: String
    let onDone: (String) -> Void
    let onCancel: () -> Void

    @State private var setup = PINSetupState()

    var body: some View {
        PINPad(
            title: setup.isConfirming
                ? String(localized: "Enter the PIN again", bundle: .module)
                : String(localized: "Choose a 4-digit PIN", bundle: .module),
            message: message,
            messageIsError: setup.mismatched,
            onSubmit: { pin in
                switch setup.submit(pin) {
                case .confirmNext: return .next
                case .mismatch: return .mismatched
                case .done(let pin):
                    onDone(pin)
                    return .accepted
                }
            },
            onCancel: onCancel
        ) {
            PINLockGlyph()
        }
        .pinSheetChrome()
    }

    private var message: String {
        if setup.mismatched {
            return String(localized: "Those PINs didn’t match. Choose one again.", bundle: .module)
        }
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Asked whenever someone switches to this profile.", bundle: .module)
            : String(localized: "Asked whenever someone switches to \(name).", bundle: .module)
    }
}

import SwiftUI

// Controls from the mockups: the season picker, the amber switch, the dark
// search field and the dashed "add" tiles.

/// A row of segments on a dark track, the selected one raised: "Season 1 /
/// Season 2 / Season 3" on a show, "Guide / Multi-view" in the Mac toolbar.
///
/// Up to four regular segments share the width; more (or any number at an
/// accessibility text size) scroll sideways at their own widths so a label
/// never truncates. Each segment is a button with the selected trait, at
/// least 44 pt tall to touch; the highlight slides between segments unless
/// Reduce Motion is on.
public struct SegmentedPills<Value: Hashable>: View {
    public enum Size: Sendable {
        /// 40 pt segments on a 48 pt track, 14 pt type: a show's seasons.
        case regular
        /// 26 pt segments, 13 pt type, intrinsic widths: a Mac toolbar. The
        /// touch area is still padded to 44.
        case compact
    }

    private let label: String
    private let options: [Value]
    @Binding private var selection: Value
    private let size: Size
    private let title: (Value) -> String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    /// - Parameters:
    ///   - label: What the group picks, for VoiceOver ("Seasons").
    ///   - title: The text of each segment.
    public init(_ label: String, options: [Value], selection: Binding<Value>, size: Size = .regular, title: @escaping (Value) -> String) {
        self.label = label
        self.options = options
        self._selection = selection
        self.size = size
        self.title = title
    }

    public var body: some View {
        Group {
            switch size {
            case .regular:
                if SegmentedPillsLayout.usesEqualWidths(count: options.count, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                    segments(fillWidth: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        segments(fillWidth: false)
                    }
                }
            case .compact:
                segments(fillWidth: false)
            }
        }
        .padding(.horizontal, size == .regular ? 4 : 3)
        .padding(.vertical, size == .regular ? 2 : 0)
        .background(
            // A compact track is drawn 32 pt tall inside its segments' 44 pt
            // touch band: 26 + 3 + 3.
            RoundedRectangle(cornerRadius: size == .regular ? 14 : 9, style: .continuous)
                .fill(HearthColor.surface)
                .padding(.vertical, size == .regular ? 0 : (HearthMetrics.minimumHitTarget - 32) / 2)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    private func segments(fillWidth: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                segment(option, fillWidth: fillWidth)
            }
        }
    }

    private func segment(_ option: Value, fillWidth: Bool) -> some View {
        let isSelected = option == selection
        let shape = RoundedRectangle(cornerRadius: size == .regular ? 10 : 7, style: .continuous)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                selection = option
            }
        } label: {
            Text(title(option))
                .font(.hearthText(size == .regular ? 14 : 13, weight: isSelected ? .semibold : .medium, relativeTo: .callout))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? HearthColor.textPrimary : HearthColor.textSecondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: size == .regular ? 40 : 26)
                .background {
                    if isSelected {
                        shape.fill(HearthColor.selection)
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                // Pads the touch area to 44 while the highlight stays the
                // mockup's 40 (regular) or 26 (compact).
                .padding(.vertical, size == .regular ? 2 : 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SegmentedPills where Value == String {
    /// Segments whose values are their titles.
    public init(_ label: String, options: [String], selection: Binding<String>, size: Size = .regular) {
        self.init(label, options: options, selection: selection, size: size) { $0 }
    }
}

/// The amber switch from Household's Sync rows: a 51 × 31 track, amber when
/// on, with a white knob. The label leads and the switch trails, filling the
/// row as the system switch does; the whole row toggles. VoiceOver sees a
/// standard switch, and the knob slides only when Reduce Motion is off.
public struct AmberToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        AmberToggleBody(configuration: configuration)
    }
}

private struct AmberToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .foregroundStyle(HearthColor.textPrimary)
                Spacer(minLength: 0)
                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? HearthColor.accent : HearthColor.dashedStroke)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .offset(x: configuration.isOn ? 10 : -10)
                }
                .frame(width: 51, height: 31)
            }
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            // The system switch, so VoiceOver says "switch, on" and offers
            // the toggle action. Styled `.switch` explicitly so this
            // representation can't pick up the amber style again.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == AmberToggleStyle {
    /// `.toggleStyle(.amber)`.
    public static var amber: AmberToggleStyle { AmberToggleStyle() }
}

/// The dark rounded search field: the Mac sidebar's "Search everything", and
/// the phone's search screen. A magnifier, the field, and a clear button once
/// there is text.
public struct SearchField: View {
    public enum Size: Sendable {
        /// 44 pt, 15 pt type: a phone or iPad screen.
        case regular
        /// 34 pt, 13 pt type: the Mac sidebar, where a pointer does the
        /// touching.
        case compact
    }

    private let prompt: String
    @Binding private var text: String
    private let size: Size
    private let focus: FocusState<Bool>.Binding?
    private let onSubmit: (() -> Void)?

    /// - Parameters:
    ///   - prompt: The placeholder, also the field's VoiceOver label.
    ///   - focus: Bind to focus the field from outside (Search's first
    ///     appearance, ⌘F on the Mac).
    ///   - onSubmit: Return / Search pressed.
    public init(_ prompt: String, text: Binding<String>, size: Size = .regular, focus: FocusState<Bool>.Binding? = nil, onSubmit: (() -> Void)? = nil) {
        self.prompt = prompt
        self._text = text
        self.size = size
        self.focus = focus
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let regular = size == .regular
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: regular ? 15 : 13, weight: .medium))
                .foregroundStyle(HearthColor.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(HearthColor.textTertiary))
                .textFieldStyle(.plain)
                .font(.hearthText(regular ? 15 : 13, relativeTo: .body))
                .foregroundStyle(HearthColor.textPrimary)
                .noAutocapitalization()
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .modifier(OptionalFocus(binding: focus))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: regular ? 16 : 13))
                        .foregroundStyle(HearthColor.textTertiary)
                        .frame(width: regular ? HearthMetrics.minimumHitTarget : 28, height: regular ? HearthMetrics.minimumHitTarget : 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, regular ? -12 : -6)
                .accessibilityLabel(Text("Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, regular ? 14 : 10)
        .frame(minHeight: regular ? HearthMetrics.minimumHitTarget : 34)
        .background(
            RoundedRectangle(cornerRadius: regular ? HearthMetrics.controlRadius : 9, style: .continuous)
                .fill(HearthColor.surfaceOverlay)
        )
    }
}

/// Applies `.focused(_:)` only when the caller passed a binding.
private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

/// A dashed outline that adds something: "Add profile" on the profile gate,
/// "Add a channel" in an empty multi-view tile.
public struct DashedAddTile: View {
    public enum Style: Sendable {
        /// A square the size of a profile avatar with the title under it.
        case profile
        /// A panel that fills its frame, with a round plus, the title and an
        /// optional message centred in it.
        case panel
    }

    public var title: String
    public var message: String?
    public var style: Style
    public var size: CGFloat
    public var action: () -> Void

    /// - Parameter size: The square's side for `.profile` (96 on the profile
    ///   gate); ignored by `.panel`, which takes the space it is given.
    public init(_ title: String, message: String? = nil, style: Style = .profile, size: CGFloat = 96, action: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.style = style
        self.size = size
        self.action = action
    }

    private var dash: StrokeStyle { StrokeStyle(lineWidth: 2, dash: [5, 4]) }

    public var body: some View {
        Button(action: action) {
            switch style {
            case .profile: profile
            case .panel: panel
            }
        }
        .buttonStyle(.hearthTile)
        .accessibilityLabel(Text(title))
        .accessibilityHint(message.map { Text($0) } ?? Text(verbatim: ""))
    }

    private var profile: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(HearthColor.dashedStroke, style: dash)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.28, weight: .medium))
                        .foregroundStyle(HearthColor.textSecondary)
                }
            Text(title)
                .font(.hearthText(16, weight: .medium, relativeTo: .body))
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: HearthMetrics.tileRadius, style: .continuous)
        return VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(HearthColor.textPrimary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(HearthColor.surfaceButton))
            Text(title)
                .font(.hearthText(16, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(HearthColor.textPrimary)
            if let message {
                Text(message)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(HearthColor.sidebar))
        .overlay(shape.strokeBorder(Color(hex: 0x2F333D), style: dash))
    }
}

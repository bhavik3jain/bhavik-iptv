import SwiftUI
import UniformTypeIdentifiers

#if os(iOS) || os(tvOS)
import UIKit
#endif

// Every platform conditional a feature package needs lives here, in Core.
// Feature packages contain no `#if os(...)`: an iOS-only modifier needed in a
// feature means a shim in this file, not a conditional at the call site.
// tvOS is neither `os(iOS)` nor `os(macOS)`: each shim says what it does there.

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS, nothing on the Mac
    /// or the TV.
    public func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.navigationBarTitleDisplayMode(.large)` on iOS, nothing on the Mac
    /// or the TV.
    public func largeNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    /// A number pad on iOS and the TV (PINs, channel numbers), nothing on
    /// the Mac.
    public func numberPadKeyboard() -> some View {
        #if os(iOS) || os(tvOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// A URL keyboard with no autocapitalisation or autocorrection (portal
    /// URLs, MAC addresses).
    public func urlEntryKeyboard() -> some View {
        #if os(iOS) || os(tvOS)
        self.keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Plain text with no autocapitalisation (usernames, MAC addresses).
    public func noAutocapitalization() -> some View {
        #if os(iOS) || os(tvOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// `fullScreenCover` on iOS and the TV; a large sheet on the Mac, which
    /// has none.
    public func hearthFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS) || os(tvOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item) { value in
            content(value).frame(minWidth: 960, minHeight: 600)
        }
        #endif
    }

    /// `fullScreenCover(isPresented:)` on iOS and the TV; a large sheet on
    /// the Mac.
    public func hearthFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS) || os(tvOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented) {
            content().frame(minWidth: 960, minHeight: 600)
        }
        #endif
    }

    /// Hides the iOS status bar (the player); nothing on the Mac or the TV.
    public func hearthStatusBarHidden(_ hidden: Bool = true) -> some View {
        #if os(iOS)
        self.statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// The horizontal size class as a layout: `.sidebar` when regular (iPad,
    /// iPhone Duo's inner display), `.compact` otherwise. Always `.sidebar` on
    /// the Mac and `.tv` on the Apple TV. Applied once by the app at the root.
    public func hearthLayoutFromSizeClass() -> some View {
        modifier(HearthLayoutFromSizeClass())
    }

    // MARK: Added for the Apple TV

    /// `.textSelection(.enabled)` where text can be selected (iOS, the Mac);
    /// nothing on the TV, which has no selection.
    public func hearthTextSelectable() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }

    /// `.keyboardShortcut(key, modifiers:)` on iOS and the Mac; the TV has no
    /// keyboard shortcuts.
    public func hearthKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        #if os(tvOS)
        self
        #else
        self.keyboardShortcut(key, modifiers: modifiers)
        #endif
    }

    /// `.keyboardShortcut(.cancelAction)` (Esc) on iOS and the Mac; on the
    /// TV the remote's Menu button already backs out.
    public func hearthCancelShortcut() -> some View {
        #if os(tvOS)
        self
        #else
        self.keyboardShortcut(.cancelAction)
        #endif
    }

    /// `.keyboardShortcut(.defaultAction)` (Return) on iOS and the Mac;
    /// nothing on the TV.
    public func hearthDefaultActionShortcut() -> some View {
        #if os(tvOS)
        self
        #else
        self.keyboardShortcut(.defaultAction)
        #endif
    }

    /// `.listRowSeparatorTint` where lists draw separators; the TV's grouped
    /// lists have none.
    public func hearthListRowSeparatorTint(_ color: Color) -> some View {
        #if os(tvOS)
        self
        #else
        self.listRowSeparatorTint(color)
        #endif
    }

    /// `.scrollContentBackground(.hidden)` where a list or form draws its
    /// own background (iOS, the Mac); the TV's lists are already clear.
    public func hearthScrollContentBackgroundHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    /// `.navigationBarBackButtonHidden` where there is a back button; the
    /// TV goes back with the remote's Menu button.
    public func hearthNavigationBarBackButtonHidden(_ hidden: Bool) -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationBarBackButtonHidden(hidden)
        #endif
    }

    /// `.fileImporter` on iOS and the Mac. The TV has no files to pick:
    /// nothing is presented, so the caller should offer the button only where
    /// `HearthPlatform.canPickFiles` is true.
    public func hearthFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onCompletion: @escaping (Result<URL, any Error>) -> Void
    ) -> some View {
        #if os(tvOS)
        self
        #else
        self.fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, onCompletion: onCompletion)
        #endif
    }

    /// A drop target for item keys dragged as strings (multi-view's channel
    /// list onto a tile). The TV has no drag and drop.
    public func hearthStringDropDestination(_ action: @escaping ([String]) -> Bool) -> some View {
        #if os(tvOS)
        self
        #else
        self.dropDestination(for: String.self) { items, _ in action(items) }
        #endif
    }

    /// A swipe down to dismiss, for cards over other content; the TV
    /// dismisses with the Menu button instead (`onClose` is run for both).
    public func hearthSwipeDownToDismiss(offset: Binding<CGFloat>, animation: Animation?, onClose: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self.onExitCommand(perform: onClose)
        #else
        self.gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { offset.wrappedValue = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 70 || value.predictedEndTranslation.height > 160 {
                        onClose()
                    }
                    withAnimation(animation) { offset.wrappedValue = 0 }
                }
        )
        #endif
    }

    /// `.focusSection()` on the TV and the Mac: a row or column the focus
    /// engine treats as one target when moving into it from far away, so a
    /// swipe down from a short row lands in the next row rather than nowhere.
    /// Nothing on iOS.
    public func hearthFocusSection() -> some View {
        #if os(tvOS) || os(macOS)
        self.focusSection()
        #else
        self
        #endif
    }

    /// The system card style on the TV (the lift, shadow and parallax tvOS
    /// gives posters); plain everywhere else.
    @ViewBuilder
    public func hearthCardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// The remote's Menu button (and the Mac's Esc): `action` instead of the
    /// system's back. Nothing on iOS.
    public func hearthOnExitCommand(_ action: (() -> Void)?) -> some View {
        #if os(tvOS) || os(macOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

/// What the platform can do, for the few choices a feature can't make from
/// the layout alone (whether to offer a button at all).
public enum HearthPlatform {
    /// A file picker exists (iOS, the Mac): M3U playlists from Files.
    public static var canPickFiles: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// The system share sheet exists (iOS, the Mac).
    public static var canShare: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Typing is comfortable: a keyboard or a touch screen. On the TV text is
    /// entered letter by letter with the remote, so long forms (a portal's
    /// login) are better done on a phone in the same household.
    public static var hasComfortableTextEntry: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }
}

/// `ShareLink(item:label:)` on iOS and the Mac; nothing on the TV, which has
/// no share sheet.
public struct HearthShareLink<Label: View>: View {
    let item: String
    let label: Label

    public init(item: String, @ViewBuilder label: () -> Label) {
        self.item = item
        self.label = label()
    }

    public var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        ShareLink(item: item) { label }
        #endif
    }
}

/// `Stepper(value:in:)` on iOS and the Mac. The TV has no stepper, so it
/// gets − and + buttons beside the label instead.
public struct HearthStepper<Label: View>: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: Label

    public init(value: Binding<Int>, in range: ClosedRange<Int>, @ViewBuilder label: () -> Label) {
        _value = value
        self.range = range
        self.label = label()
    }

    public var body: some View {
        #if os(tvOS)
        HStack(spacing: 16) {
            label
            Button {
                value = max(range.lowerBound, value - 1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel(Text("Fewer"))
            Button {
                value = min(range.upperBound, value + 1)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel(Text("More"))
        }
        #else
        Stepper(value: $value, in: range) { label }
        #endif
    }
}

/// `DisclosureGroup(isExpanded:)` on iOS and the Mac. The TV has none, so
/// the label becomes a button that shows and hides the content below it.
public struct HearthDisclosureGroup<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    let content: Content
    let label: Label

    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        _isExpanded = isExpanded
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        #if os(tvOS)
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                label
                Spacer(minLength: 16)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .accessibilityHidden(true)
            }
        }
        if isExpanded {
            content
        }
        #else
        DisclosureGroup(isExpanded: $isExpanded) { content } label: { label }
        #endif
    }
}

private struct HearthLayoutFromSizeClass: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.hearthLayout, horizontalSizeClass == .regular ? .sidebar : .compact)
        #elseif os(tvOS)
        content.environment(\.hearthLayout, .tv)
        #else
        content.environment(\.hearthLayout, .sidebar)
        #endif
    }
}

/// The device's user-visible name for who's-watching records ("Living Room
/// iPad", "Bhavik's MacBook Pro", "Apple TV").
public enum DeviceName {
    @MainActor
    public static var current: String {
        #if os(iOS) || os(tvOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

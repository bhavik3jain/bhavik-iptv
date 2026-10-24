import SwiftUI

// Every platform conditional a feature package needs lives here, in Core.
// Feature packages contain no `#if os(...)`: an iOS-only modifier needed in a
// feature means a shim in this file, not a conditional at the call site.

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS, nothing on the Mac.
    public func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.navigationBarTitleDisplayMode(.large)` on iOS, nothing on the Mac.
    public func largeNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    /// A number pad on iOS (PINs, channel numbers), nothing on the Mac.
    public func numberPadKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// A URL keyboard with no autocapitalisation or autocorrection (portal
    /// URLs, MAC addresses).
    public func urlEntryKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Plain text with no autocapitalisation (usernames, MAC addresses).
    public func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// `fullScreenCover` on iOS; a large sheet on the Mac, which has none.
    public func hearthFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item) { value in
            content(value).frame(minWidth: 960, minHeight: 600)
        }
        #endif
    }

    /// `fullScreenCover(isPresented:)` on iOS; a large sheet on the Mac.
    public func hearthFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented) {
            content().frame(minWidth: 960, minHeight: 600)
        }
        #endif
    }

    /// Hides the iOS status bar (the player); nothing on the Mac.
    public func hearthStatusBarHidden(_ hidden: Bool = true) -> some View {
        #if os(iOS)
        self.statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// The horizontal size class as a layout: `.sidebar` when regular (iPad,
    /// iPhone Duo's inner display), `.compact` otherwise. Always `.sidebar` on
    /// the Mac. Applied once by the app at the root.
    public func hearthLayoutFromSizeClass() -> some View {
        modifier(HearthLayoutFromSizeClass())
    }
}

private struct HearthLayoutFromSizeClass: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.hearthLayout, horizontalSizeClass == .regular ? .sidebar : .compact)
        #else
        content.environment(\.hearthLayout, .sidebar)
        #endif
    }
}

/// The device's user-visible name for who's-watching records ("Living Room
/// iPad", "Bhavik's MacBook Pro").
public enum DeviceName {
    @MainActor
    public static var current: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

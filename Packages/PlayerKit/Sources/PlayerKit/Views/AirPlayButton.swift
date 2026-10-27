import AVFoundation
import AVKit
import Core
import SwiftUI

/// The AirPlay button in the player's top bar (PLY-3): the system's own route
/// picker, drawn white on the player's translucent circle.
///
/// The picker is the only way to offer AirPlay — there is no API to list
/// routes — so it is wrapped rather than imitated. On iOS it routes the whole
/// audio session (AVPlayer's video follows because it allows external
/// playback); on the Mac it routes one player, so the engine's AVPlayer is
/// handed to it, and with VLCKit (which can't AirPlay video, only mirror) it
/// picks the audio output.
///
/// The Apple TV is the AirPlay receiver, not a sender: there the button
/// isn't drawn (its speakers are picked in the system's Control Center).
struct AirPlayButton: View {
    var player: AVPlayer?

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        AirPlayRoutePicker(player: player)
            .frame(width: 24, height: 24)
            .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
            .background(Circle().fill(PlayerPalette.glass))
            .contentShape(Circle())
            .accessibilityLabel(Text("AirPlay"))
        #endif
    }
}

/// The AirPlay route button for screens outside the player (Home's header,
/// mockup 02): the same system picker on the raised circle the other header
/// buttons use. With no player it routes the audio session, so the next
/// stream starts on the chosen Apple TV.
public struct AirPlayRouteButton: View {
    public init() {}

    public var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        AirPlayRoutePicker(player: nil)
            .frame(width: 24, height: 24)
            .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
            .background(Circle().fill(HearthColor.surfaceRaised))
            .contentShape(Circle())
            .accessibilityLabel(Text("AirPlay"))
        #endif
    }
}

/// `AVRoutePickerView` for SwiftUI on both platforms.
@MainActor
struct AirPlayRoutePicker {
    var player: AVPlayer?
}

#if os(iOS)
extension AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = .white
        view.activeTintColor = UIColor(HearthColor.accent)
        // Apple TVs first: this is a video app.
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
extension AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor(HearthColor.accent), for: .active)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif

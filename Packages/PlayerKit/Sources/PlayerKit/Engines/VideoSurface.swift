import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
typealias PlatformView = NSView
#endif

/// Hosts an engine-owned video view in SwiftUI.
///
/// The engine keeps one view for its whole life — picture in picture holds
/// on to AVPlayer's layer and VLCKit renders into its drawable — so SwiftUI
/// gets a fresh container each time and the engine's view is moved into it.
/// The container only removes the view on dismantle if it still owns it, so a
/// second surface (the player screen over a multi-view tile) can take it over.
@MainActor
struct EngineVideoSurface {
    let content: PlatformView
}

#if os(iOS)
extension EngineVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        adopt(into: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if content.superview !== container { adopt(into: container) }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func adopt(into container: UIView) {
        // A previous engine's view (AVPlayer before a VLCKit retry) goes.
        for view in container.subviews where view !== content {
            view.removeFromSuperview()
        }
        content.removeFromSuperview()
        content.frame = container.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(content)
    }
}
#elseif os(macOS)
extension EngineVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if content.superview !== container { adopt(into: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func adopt(into container: NSView) {
        // A previous engine's view (AVPlayer before a VLCKit retry) goes.
        for view in container.subviews where view !== content {
            view.removeFromSuperview()
        }
        content.removeFromSuperview()
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }
}
#endif

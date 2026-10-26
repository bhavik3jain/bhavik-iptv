import CloudKit
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The system iCloud sharing UI for an existing share (HH-2), behind one
// modifier so the Household feature needs no `#if os(...)`. iOS has
// `UICloudSharingController`; the Mac has the Cloud Sharing service
// (`NSSharingService(named: .cloudSharing)`, or `NSSharingServicePicker` when
// the service declines) driven by an item provider that carries the share.
// Both are handed a share that is already saved with a
// link — HouseholdKit's `prepareShare()` makes it off the main thread with
// every wait bounded — never the deprecated preparation-handler form, which
// ran `share()` inside the controller with no way to say why it spun
// (Multitrack's lesson, see its ShareSheetHost).

/// A saved household share and its container, ready for the system sharing
/// UI. Set one on `cloudSharingSheet(invitation:onDismiss:)`'s binding to
/// show it.
public struct CloudShareInvitation: Identifiable {
    public let id = UUID()
    public let share: CKShare
    public let container: CKContainer

    public init(share: CKShare, container: CKContainer) {
        self.share = share
        self.container = container
    }
}

extension View {
    /// Shows the system iCloud sharing UI while `invitation` is set: people,
    /// their access, Messages / Mail / Copy Link. The binding goes back to nil
    /// once the UI is up; `onDismiss` runs when it closes (people may have
    /// been added or removed, so look the share up again then).
    ///
    /// Attach it to the button that invites: the Mac anchors its popover
    /// there, and iOS presents from that button's own window, so the right
    /// scene gets it on an iPad with several windows. Participants may only
    /// read and write privately: the app's roles, not iCloud's, limit what
    /// they can change.
    public func cloudSharingSheet(invitation: Binding<CloudShareInvitation?>, onDismiss: @escaping @MainActor () -> Void = {}) -> some View {
        background(CloudSharingAnchor(invitation: invitation, onDismiss: onDismiss).accessibilityHidden(true))
    }
}

// MARK: - iOS

#if os(iOS)
private struct CloudSharingAnchor: UIViewRepresentable {
    @Binding var invitation: CloudShareInvitation?
    let onDismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        guard let invitation else { return }
        // Presented, and the binding cleared, after this update pass: UIKit
        // presentation and state writes don't belong inside a SwiftUI
        // update. The coordinator remembers the id, so a redraw before the
        // binding clears never presents the same share twice.
        let coordinator = context.coordinator
        let binding = $invitation
        DispatchQueue.main.async {
            coordinator.present(invitation, from: view)
            binding.wrappedValue = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var onDismiss: @MainActor () -> Void = {}
        /// The invitation last presented: a redraw before the binding clears
        /// must not present it again.
        private var presentedID: UUID?

        func present(_ invitation: CloudShareInvitation, from anchor: UIView) {
            guard presentedID != invitation.id else { return }
            presentedID = invitation.id
            // Looked up now, not when Invite was tapped: preparing took a
            // moment and whatever was on top then may have gone. Never a
            // second sharing UI over one that's already up.
            guard let presenter = Self.topViewController(above: anchor.window?.rootViewController ?? Self.keyWindowRoot()),
                  !(presenter is UICloudSharingController) else { return }
            let controller = DismissReportingSharingController(share: invitation.share, container: invitation.container)
            controller.availablePermissions = [.allowPrivate, .allowReadWrite]
            controller.delegate = self
            controller.onDismiss = { [weak self] in self?.onDismiss() }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            }
            presenter.present(controller, animated: true)
        }

        /// The frontmost controller: Household may itself sit in a sheet.
        private static func topViewController(above root: UIViewController?) -> UIViewController? {
            var top = root
            while let presented = top?.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            return top
        }

        /// Only when the anchor isn't in a window yet: the foreground scene's
        /// key window (never `UIScreen.main`).
        private static func keyWindowRoot() -> UIViewController? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .keyWindow?.rootViewController
        }

        // The controller shows its own error for a failed save.
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: any Error) {}

        // The share carries the household's name as its title.
        func itemTitle(for csc: UICloudSharingController) -> String? { nil }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {}
    }
}

/// `UICloudSharingController` with a callback when it goes away. Its delegate
/// has no "closed" call and its presentation controller's delegate hears only
/// swipe-downs, so the controller says so itself when it is dismissed (not
/// when Messages or Mail is presented over it).
private final class DismissReportingSharingController: UICloudSharingController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?()
            onDismiss = nil
        }
    }
}
#endif

// MARK: - macOS

#if os(macOS)
private struct CloudSharingAnchor: NSViewRepresentable {
    @Binding var invitation: CloudShareInvitation?
    let onDismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        guard let invitation else { return }
        // As on iOS: after this update pass, once.
        let coordinator = context.coordinator
        let binding = $invitation
        DispatchQueue.main.async {
            coordinator.present(invitation, from: view)
            binding.wrappedValue = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onDismiss: @MainActor () -> Void = {}
        fileprivate weak var anchor: NSView?
        /// The service while its window is up; it is released when it closes.
        fileprivate var service: NSSharingService?
        /// The fallback picker while it is up.
        fileprivate var picker: NSSharingServicePicker?
        private var presentedID: UUID?

        func present(_ invitation: CloudShareInvitation, from anchor: NSView) {
            guard presentedID != invitation.id else { return }
            presentedID = invitation.id
            guard service == nil, picker == nil else { return }
            let provider = NSItemProvider()
            provider.registerCloudKitShare(invitation.share, container: invitation.container)
            self.anchor = anchor
            if let service = NSSharingService(named: .cloudSharing), service.canPerform(withItems: [provider]) {
                self.service = service
                service.delegate = self
                service.perform(withItems: [provider])
            } else if anchor.window != nil {
                // The Cloud Sharing service declined the item directly; the
                // share picker offers the same people-and-permissions UI
                // among its entries, so Invite never silently does nothing.
                let picker = NSSharingServicePicker(items: [provider])
                picker.delegate = self
                self.picker = picker
                picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            } else {
                onDismiss()
            }
        }

        fileprivate func finish() {
            service = nil
            picker = nil
            onDismiss()
        }
    }
}

extension CloudSharingAnchor.Coordinator: @preconcurrency NSSharingServicePickerDelegate {
    /// The chosen service reports back here, so its completion closes up.
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        picker = nil
        if let service {
            self.service = service
        } else {
            finish()
        }
    }
}

extension CloudSharingAnchor.Coordinator: @preconcurrency NSCloudSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: (any Error)?) {
        finish()
    }

    // A service other than Cloud Sharing, picked from the fallback picker.
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        finish()
    }

    func options(for cloudKitSharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadWrite]
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        anchor?.window ?? NSApp.keyWindow
    }

    /// The popover points at the Invite button the modifier sits on.
    func anchoringView(for sharingService: NSSharingService, showRelativeTo positioningRect: UnsafeMutablePointer<NSRect>, preferredEdge: UnsafeMutablePointer<NSRectEdge>) -> NSView? {
        guard let anchor, anchor.window != nil else { return nil }
        positioningRect.pointee = anchor.bounds
        preferredEdge.pointee = .minY
        return anchor
    }
}
#endif

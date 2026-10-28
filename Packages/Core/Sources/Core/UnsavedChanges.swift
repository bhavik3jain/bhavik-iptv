import Foundation
import Observation
import SwiftUI

/// `@Environment(\.unsavedChanges)`: a screen holding typing it would lose
/// (the source editor) marks itself here while it does, so the app can ask
/// before a tab or sidebar switch throws that typing away — on the Mac a
/// switch rebuilds the section's stack, and the editor's state with it.
/// Nil outside the app (previews, tests), where nothing asks.
@MainActor
@Observable
public final class UnsavedChanges {
    private var owners: Set<UUID> = []

    public init() {}

    /// True when no screen has unsaved changes.
    public var isEmpty: Bool { owners.isEmpty }

    /// A screen's own state, by an id it keeps for its lifetime.
    public func mark(_ owner: UUID, hasChanges: Bool) {
        if hasChanges {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }
    }

    /// The user chose to discard: nothing holds the switch back any more.
    public func discardAll() {
        owners.removeAll()
    }
}

extension EnvironmentValues {
    @Entry public var unsavedChanges: UnsavedChanges? = nil
}

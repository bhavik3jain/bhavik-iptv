import Core
import Testing
@testable import HouseholdFeature

/// Household offers changes only where they can be made: the TV shows the
/// household, and sources, people and profiles change on another device.
@Suite struct HouseholdEditingTests {
    @Test(arguments: [HearthLayout.compact, .sidebar])
    func aManagerEditsOnAPhoneIPadOrMac(layout: HearthLayout) {
        #expect(HouseholdEditing.isOffered(canManage: true, layout: layout))
        #expect(!HouseholdEditing.isOffered(canManage: false, layout: layout))
    }

    @Test func theTVNeverOffersAChange() {
        #expect(!HouseholdEditing.isOffered(canManage: true, layout: .tv))
        #expect(!HouseholdEditing.isOffered(canManage: false, layout: .tv))
    }
}
